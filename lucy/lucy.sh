#!/bin/sh
#
# jmeter-ecs Orchestrator, aka 'Lucy'

# Leverages the AWS CLI tool and the AWS ECS CLI tool:
# http://docs.aws.amazon.com/AmazonECS/latest/developerguide/ECS_AWSCLI.html
# http://docs.aws.amazon.com/AmazonECS/latest/developerguide/ECS_CLI.html

# if the command line is not a .jmx file, then it's another command the user wants to call
if [ "${1}" != '' ]; then
  if [ ${1} == 'setup' ]; then
    if [ "$AWS_DEFAULT_REGION" == '' ]; then
      echo "Define the AWS_DEFAULT_REGION environment variable"
      exit 10
    fi
    if [ "$AWS_ACCESS_KEY_ID" == '' ]; then
      echo "Define the AWS_ACCESS_KEY_ID environment variable"
      exit 10
    fi
    if [ "$AWS_SECRET_ACCESS_KEY" == '' ]; then
      echo "Define the AWS_SECRET_ACCESS_KEY environment variable"
      exit 10
    fi
    exec /opt/jmeter/aws-setup.sh
  fi
  if [ ${1##*.} != 'jmx' ]; then
    exec "$@"
  fi
fi

if [ "$LAUNCH_TYPE" == 'FARGATE' ]; then
  exec /opt/jmeter/lucy-fargate.sh $1
fi

# check for all required variables
if [ "$1" != '' ]; then
  INPUT_JMX=$1
fi
if [ "$INPUT_JMX" == '' ]; then
  echo "Please set a INPUT_JMX or pass a JMX file on the command line"
  exit 1
fi
if [ "$S3_BUCKET" == '' ]; then
  if [ "$KEY_NAME" == '' ]; then
    echo "Please specify KEY_NAME and provide the filename (without the path and extension)"
    exit 2
  fi
fi
if [ "$SECURITY_GROUP" == '' ]; then
  echo "Please set a SECURITY_GROUP that allows ports 22,1099,50000,51000/tcp and 4445/udp from all ports (e.g. sg-12345678)"
  exit 3
fi
if [ "$SUBNET_ID" == '' ]; then
  echo "ECS requires using a VPC, so you must specify a SUBNET_ID of yor VPC"
  exit 4
fi

# check all optional variables
if [ "$JMETER_VERSION" == '' ]; then
  JMETER_VERSION=latest
fi
if [ "$AWS_REGION" == '' ]; then
  AWS_REGION=$AWS_DEFAULT_REGION
fi
if [ "$AWS_REGION" == '' ]; then
  AWS_REGION=$(aws configure get region)
fi
if [ "$AWS_ACCESS_KEY_ID" == '' ]; then
  AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
fi
if [ "$AWS_SECRET_ACCESS_KEY" == '' ]; then
  AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
fi
if [ "$INSTANCE_TYPE" == '' ]; then
  INSTANCE_TYPE=t2.micro
fi
if [ "$MEM_LIMIT" == '' ]; then
  MEM_LIMIT=950m
fi
if [ "$MINION_COUNT" == '' ]; then
  MINION_COUNT=2
fi
if [ "$PEM_PATH" == '' ]; then
  PEM_PATH=/keys
fi
if [ "$CLUSTER_NAME" == '' ]; then
  CLUSTER_NAME=JMeter
fi
if [ "$GRU_TASK_NAME" == '' ]; then
  GRU_TASK_NAME=jmeter-gru
fi
if [ "$MINION_TASK_NAME" == '' ]; then
  MINION_TASK_NAME=jmeter-minion
fi
if [ "$VPC_ID" == '' ]; then
  VPC_ID=$(aws ec2 describe-security-groups --group-ids $SECURITY_GROUP --query 'SecurityGroups[*].[VpcId]' --output text)
fi

# Step 1 - Create our ECS Cluster with MINION_COUNT+1 instances
ecs-cli --version
echo "Creating cluster/$CLUSTER_NAME"
INSTANCE_COUNT=$((MINION_COUNT+1))
if [ "$S3_BUCKET" == '' ]; then
  ecs-cli up --cluster $CLUSTER_NAME --size $INSTANCE_COUNT --capability-iam --instance-type $INSTANCE_TYPE --keypair $KEY_NAME \
    --security-group $SECURITY_GROUP --vpc $VPC_ID --subnets $SUBNET_ID --force
else
  ecs-cli up --cluster $CLUSTER_NAME --size $INSTANCE_COUNT --capability-iam --instance-type $INSTANCE_TYPE \
    --security-group $SECURITY_GROUP --vpc $VPC_ID --subnets $SUBNET_ID --force
fi
if [ $? != 0 ]; then
  echo "ecs-cli up failed with error $?"
  ecs-cli down --cluster $CLUSTER_NAME --force
  exit $?
fi

# Step 2 - Wait for the cluster to have all container instances registered
while true; do
  CONTAINER_INSTANCE_COUNT=$(aws ecs describe-clusters --cluster $CLUSTER_NAME \
    --query 'clusters[*].[registeredContainerInstancesCount]' --output text)
  echo "Instance count is $CONTAINER_INSTANCE_COUNT"
  if [ "$CONTAINER_INSTANCE_COUNT" == $INSTANCE_COUNT ]; then
    break
  fi
  sleep 10
done

# Step 3 - Run the Minion task with the requested JMeter version, instance count and memory
sed -i 's/jmeter:latest/jmeter:'"$JMETER_VERSION"'/' /opt/jmeter/minion.yml
sed -i 's/950m/'"$MEM_LIMIT"'/' /opt/jmeter/minion.yml
ecs-cli compose --file /opt/jmeter/minion.yml up --cluster $CLUSTER_NAME
ecs-cli compose --file /opt/jmeter/minion.yml --cluster $CLUSTER_NAME scale $MINION_COUNT

# Step 4 - Get Gru and Minion's instance ID's.  Gru is the container with a runningTasksCount = 0
CONTAINER_INSTANCE_IDS=$(aws ecs list-container-instances --cluster $CLUSTER_NAME --output text |
      awk '{print $2}' | tr '\n' ' ')
echo "Container instances IDs: $CONTAINER_INSTANCE_IDS"

GRU_INSTANCE_ID=$(aws ecs describe-container-instances --cluster $CLUSTER_NAME \
  --container-instances $CONTAINER_INSTANCE_IDS --query 'containerInstances[*].[ec2InstanceId,runningTasksCount]' --output text | grep '\t0' | awk '{print $1}')
echo "Gru instance ID: $GRU_INSTANCE_ID"

MINION_INSTANCE_IDS=$(aws ecs describe-container-instances --cluster $CLUSTER_NAME \
  --container-instances $CONTAINER_INSTANCE_IDS --query 'containerInstances[*].[ec2InstanceId,runningTasksCount]' --output text | grep '\t1' | awk '{print $1}')
echo "Minion instances IDs: $MINION_INSTANCE_IDS"

# Step 5 - Get IP addresses from Gru (Public or Private) and Minions (always Private)
if [ "$GRU_PRIVATE_IP" = '' ]; then
  GRU_HOST=$(aws ec2 describe-instances --instance-ids $GRU_INSTANCE_ID \
      --query 'Reservations[*].Instances[*].[PublicIpAddress]' --output text | tr -d '\n')
else
  cho "Using Gru's Private IP"
  GRU_HOST=$(aws ec2 describe-instances --instance-ids $GRU_INSTANCE_ID \
      --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text | tr -d '\n')
fi
echo "Gru at $GRU_HOST"

MINION_HOSTS=$(aws ec2 describe-instances --instance-ids $MINION_INSTANCE_IDS \
      --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text | tr '\n' ',')
echo "Minions at $MINION_HOSTS"
# uncomment if you want to pause Lucy to inspect Gru or a Minion
#read -p "Press enter to start Gru setup: "

if [ "$S3_BUCKET" != '' ]; then
  # S3 based JMX Mode
  # Step 6 - Run Gru with the specified JMX
  echo "Running ecs-cli compose up to start JMeter in Gru mode"

  sed -i 's/jmeter:latest/jmeter:'"$JMETER_VERSION"'/' /opt/jmeter/gru.yml
  sed -i 's/950m/'"$MEM_LIMIT"'/' /opt/jmeter/gru.yml
  sed -i 's/$INPUT_JMX/'"$INPUT_JMX"'/' /opt/jmeter/gru.yml
  sed -i 's/$AWS_DEFAULT_REGION/'"$AWS_DEFAULT_REGION"'/g' /opt/jmeter/gru.yml
  sed -i 's/$AWS_ACCESS_KEY_ID/'"$AWS_ACCESS_KEY_ID"'/' /opt/jmeter/gru.yml
  sed -i 's|$AWS_SECRET_ACCESS_KEY|'"$AWS_SECRET_ACCESS_KEY"'|' /opt/jmeter/gru.yml
  sed -i 's/$S3_BUCKET/'"$S3_BUCKET"'/' /opt/jmeter/gru.yml
  sed -i 's/$MINION_HOSTS/'"$MINION_HOSTS"'/' /opt/jmeter/gru.yml
  ecs-cli compose --file /opt/jmeter/gru.yml --project-name $GRU_TASK_NAME up --cluster $CLUSTER_NAME --create-log-groups

  # Step 7 - Gru is posting results to S3 - wait until all instances have 0 tasks running
  while true; do
    WORKING_INSTANCE_IDS=$(aws ecs describe-container-instances --cluster $CLUSTER_NAME \
      --container-instances $CONTAINER_INSTANCE_IDS --query 'containerInstances[*].[ec2InstanceId,runningTasksCount]' --output text | grep '\t1' | awk '{print $1}')
    if [ "$WORKING_INSTANCE_IDS" == '' ]; then
      break
    fi
    echo "Instance IDs still working: $WORKING_INSTANCE_IDS"
    sleep 10
  done
else
  # Local JMX Mode
  # Step 6 - Run Gru with the specified JMX
  echo "Copying $INPUT_JMX to Gru"
  scp -i $PEM_PATH/$KEY_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $INPUT_JMX ec2-user@${GRU_HOST}:/tmp

  echo "Running Docker to start JMeter in Gru mode"
  JMX_IN_COMTAINER=/plans/$(basename $INPUT_JMX)
  ssh -i $PEM_PATH/$KEY_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ec2-user@${GRU_HOST} \
  "docker run -p 1099:1099 -p 51000:51000 -v /tmp:/plans -v /logs:/logs --env MINION_HOSTS=$MINION_HOSTS smithmicro/jmeter:$JMETER_VERSION $JMX_IN_COMTAINER"

  # Step 7 - Fetch the results from Gru
  echo "Copying results from Gru"
  scp -r -i $PEM_PATH/$KEY_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ec2-user@${GRU_HOST}:/logs/* /logs
fi

# Step 8 - Delete the cluster
echo "Deleting cluster/$CLUSTER_NAME"
ecs-cli down --cluster $CLUSTER_NAME --force

echo "Complete"
