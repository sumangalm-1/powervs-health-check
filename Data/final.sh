#!/bin/bash

: '
    Copyright (C) 2022 IBM Corporation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    Sumangal Mugalikar <Sumangal.Mugalikar@ibm.com> - Initial implementation.
    Rafael Sene <rpsene@br.ibm.com> - Initial implementation.
'
# Varible declaration for network counter
read COUNT

# Trap ctrl-c and call ctrl_c()
trap ctrl_c INT

function ctrl_c() {
    echo "Bye!"
    exit 0
}

function check_dependencies() {

    DEPENDENCIES=(ibmcloud curl sh wget jq)
    check_connectivity
    for i in "${DEPENDENCIES[@]}"
    do
        if ! command -v $i &> /dev/null; then
            echo "ERROR: $i could not be found, exiting!"
            exit 1
        fi
    done
}

function check_connectivity() {

    if ! curl --output /dev/null --silent --head --fail http://cloud.ibm.com; then
        echo
        echo "ERROR: please, check your internet connection."
        exit 1
    fi
}

function authenticate() {

    local APY_KEY="$1"
    if [ -z "$APY_KEY" ]; then
        echo "ERROR: API KEY was not set."
        exit 1
    fi
    ibmcloud login --no-region --apikey "$APY_KEY"
}

function set_powervs() {

    local CRN="$1"
    if [ -z "$CRN" ]; then
        echo "ERROR: CRN was not set."
        exit 1
    fi
    ibmcloud pi st "$CRN"
}

function create_public_network() {

    local NETWORK_NAME="$1"
    local DNS="1.1.1.1 9.9.9.9 8.8.8.8"
 
    if [ -z "$NETWORK_NAME" ]; then
        echo "ERROR: NETWORK_NAME was not set."
        exit 1
    fi
    ibmcloud pi netcpu --dns-servers "$DNS" "$NETWORK_NAME"
}

function delete_vm() {

    local VM_ID="$1"

    if [ -z "$VM_ID" ]; then
        echo "ERROR: VM_ID was not set."
        echo "VM_ID: the unique identifier or name of the VM."
        exit 1
    fi
    ibmcloud pi instance-delete "$VM_ID" --delete-data-volumes
}

function delete_network() {

    local NETWORK_ID="$1"

    if [ -z "$NETWORK_ID" ]; then
        echo "ERROR: NETWORK_ID was not set."
        echo "NETWORK_ID: the unique identifier or name of the network."
        exit 1
    fi
    ibmcloud pi network-delete "$NETWORK_ID"
}

function vm_cleanup() {

    local SERVER_ID="$1"
    local PVS_VM_NETWORK="$2"

    if [ -z "$SERVER_ID" ]; then
        echo "ERROR: SERVER_ID was not set for deletion."
        exit 1
    fi
    if [ -z "$PVS_VM_NETWORK" ]; then
        echo "ERROR: PVS_VM_NETWORK was not set for deletion."
        exit 1
    fi
    delete_vm "$SERVER_ID"
    sleep 200
    delete_network "$PVS_VM_NETWORK"
}

function error_log() {
   local SERVER_ID="$1"
   local ERRROR_LOG="$2"
    if [ -z "$ERRROR_LOG" ]; then
        echo "ERROR: ERRROR_LOG was not captured."
        exit 1
    fi
   sleep 5
  ibmcloud pi in "$SERVER_ID" --json | jq -r ".fault.details" > errorlog
}


function create_vm() {

    local PVS_VM_NAME=$1
    local PVS_IMAGE_NAME=$2
    local PVS_VM_MEMORY=$3
    local PVS_VM_NETWORK=$4
    local PVS_VM_PROCESSOR=$5
    local PVS_VM_SSH_KEY=$6
    local PVS_IMAGE_USER=$7
    local PVS_PRIVATE_SSH_KEY_PATH=$8

    local LOGS_DIR="vm-creation-logs"
    # check if the directory to keep logs exists.
    if [ -d "$LOGS_DIR" ]; then
        echo "NEWS: ${LOGS_DIR} already exits."
    else
        echo "WARNIG: ${LOGS_DIR} does not exits."
        echo "        Creating ${LOGS_DIR}..."
        mkdir -p ./vm-creation-logs || exit
    fi

    ibmcloud pi instance-create "$PVS_VM_NAME" --image "$PVS_IMAGE_NAME" \
    --memory "$PVS_VM_MEMORY" --network "$PVS_VM_NETWORK" \
    --processors "$PVS_VM_PROCESSOR" --processor-type shared \
    --key-name "$PVS_VM_SSH_KEY" --sys-type s922 --storage-type tier1 \
    --json >> ./vm-creation-logs/"$PVS_VM_NAME.log"


    # gets server ID and name
    local SERVER_ID=$(jq -r ".[].pvmInstanceID" < ./vm-creation-logs/"$PVS_VM_NAME.log")
    local SERVER_NAME=$(jq -r ".[].serverName" < ./vm-creation-logs/"$PVS_VM_NAME.log")

    echo "  $SERVER_NAME was created with the ID $SERVER_ID"
    echo "  deploying the server $SERVER_NAME, hold on please."
    local STATUS=$(ibmcloud pi in "$SERVER_ID" --json | jq -r ".status")

    # loop to get the status of the VM: ACTIVE or ERROR
    printf "%c" "    "
    while [[ "$STATUS" != "ACTIVE" ]]; do
        sleep 5
        STATUS=$(ibmcloud pi in "$SERVER_ID" --json | jq -r ".status")
        printf "%c" "."
    done
    if [[ "$STATUS" == "ERROR" ]]; then
        echo "ERROR: the vm $SERVER_NAME could not be created, destroying allocated resources..."
        local ERROR_LOG=$(ibmcloud pi in "$SERVER_ID" --json | jq -r ".fault.details" > errorlog)
        # call function to store the data about the errorlogs
        error_log "$SERVER_ID" "$ERROR_LOG"
        vm_cleanup "$SERVER_ID" "$PVS_VM_NETWORK"
        exit 1
    fi

    local NETWORK_COUNTER=0
    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo
        echo "  $SERVER_NAME is now ACTIVE."
        echo "  waiting for the network availability, hang on..."
        local EXTERNAL_IP=$(ibmcloud pi in "$SERVER_ID" --json | jq -r '.addresses[0].externalIP')

        # loop to collect the VM IPs.
        printf "%c" "    "
        while [[ -z "$EXTERNAL_IP" ]]; do
            printf "%c" "."
            EXTERNAL_IP=$(ibmcloud pi in "$SERVER_ID" --json | jq -r '.addresses[0].externalIP')
            sleep 5
     # create a variable for host to the n/w counter at the top of the script
            if [[ "$NETWORK_COUNTER" -gt $COUNT ]]; then
                echo "ERROR: no network available for $SERVER_NAME."
                vm_cleanup "$SERVER_ID" "$PVS_VM_NETWORK"
                exit 1
            fi
        NETWORK_COUNTER=$((NETWORK_COUNTER+1))
        done
    fi

    # loop to ping the VM and check availability via network.
    printf "%c" "    "
# counter is similar to add for pinging the public IP i.e 1000
#the if ping failed then we need to mention the entry in db and kill that execution
     while ! ping -c 1 "$EXTERNAL_IP" &> /dev/null; do
        sleep 2
        printf "%c" "."
    done

    # loop to try ssh into the VM after it is responding the ping
    local SSH_COUNTER=0
    until ssh -oStrictHostKeyChecking=no -i "$PVS_PRIVATE_SSH_KEY_PATH" "$PVS_IMAGE_USER"@"$EXTERNAL_IP" 'uname -a; exit'; do
   # set it to true
   Communicate=true
  # ...do your stu to 'false' if needed ...
    if [ "$Communicate" = true ]
    then
      echo 'SSH communication successfully established.'
    else
      echo 'ALERT: SSH communication failed.'
    fi

        sleep 2
        if [[ "$SSH_COUNTER" -gt 10 ]]; then
            echo "ERROR: we could not ssh into $SERVER_NAME."
          # we need to add the entry in db then do cleanup
            vm_cleanup "$SERVER_ID" "$PVS_VM_NETWORK"
            exit 1
        fi
        SSH_COUNTER=$((SSH_COUNTER+1))
    done

    echo
    echo "  $SERVER_NAME is ready, access it using ssh at $EXTERNAL_IP."
  # mention the ssh entry into the db and then cleanup
    vm_cleanup "$SERVER_ID" "$PVS_VM_NETWORK"
    exit 0
}


function get_instances_data(){
    echo "  - getting data from VMs..."
    local TODAY
    TODAY=$(date '+%Y%m%d')
        local PVS_NAME=$1
        local IBMCLOUD_ID=$2
        local IBMCLOUD_NAME=$3
    local PVS_ZONE=$4

    local INSTANCES=($(ibmcloud pi ins --json | jq -r '.Payload.pvmInstances[] | "\(.pvmInstanceID)"'))
for in in "${INSTANCES[@]}"; do
ibmcloud pi in "$in" --json >> "$(pwd)/$IBMCLOUD_ID/$in.json"
jq  -r "[.status,.pvmInstanceID,.serverName,.storagePool,.storageType,.serverName,.ieID,.operatingSystem,.osType,.processors,.addresses[].networkID,.addresses[].networkName,.addresses[].externalIP] | @csv" $(pwd)/$IBMCLOUD_ID/$in.json >> output
echo "VM_creation=Yes", "SSH_commucation=Yes" >>output
done
}

function run() {

    # randon string to avoid naming conficts
    local SUFIX=$(openssl rand -hex 5)

    # variables
    local VM_NAME="vm-$SUFIX"
    local VM_NETWORK="network-$SUFIX"

    if [ -z "$IBMCLOUD_API_KEY" ]; then
        echo "IBMCLOUD_API_KEY was not set."
        exit 1
    fi
    if [ -z "$POWERVS_CRN" ]; then
        echo "POWERVS_CRN was not set."
        exit 1
    fi
    if [ -z "$SUFIX" ]; then
        echo "SUFIX was not set."
        exit 1
    fi
    if [ -z "$VM_NAME" ]; then
        echo "VM_NAME was not set."
        exit 1
    fi
    if [ -z "$IMAGE_NAME" ]; then
        echo "IMAGE_NAME was not set."
        exit 1
    fi
    if [ -z "$VM_MEMORY" ]; then
        echo "VM_MEMORY was not set."
        exit 1
    fi
    if [ -z "$VM_NETWORK" ]; then
        echo "VM_NETWORK was not set."
        exit 1
    fi
    if [ -z "$VM_PROCESSOR" ]; then
        echo "VM_PROCESSOR was not set."
        exit 1
    fi
    if [ -z "$VM_SSH_KEY" ]; then
        echo "VM_SSH_KEY was not set."
        exit 1
    fi
    if [ -z "$IMAGE_USER" ]; then
        echo "IMAGE_USER was not set."
        exit 1
    fi
    if [ -z "$PRIVATE_SSH_KEY_PATH" ]; then
        echo "PRIVATE_SSH_KEY_PATH was not set."
        exit 1
    else
        if [ -s "$PRIVATE_SSH_KEY_PATH" ]; then
            echo "NEWS: $PRIVATE_SSH_KEY_PATH exists."
        else
            echo "ERROR: $PRIVATE_SSH_KEY_PATH does not exists."
            exit 1
        fi
    fi

    # step 0: preparation and login
    check_dependencies
    authenticate "$IBMCLOUD_API_KEY"
    set_powervs "$POWERVS_CRN"

    # step 1: vm deployment
    create_public_network "$VM_NETWORK"
    create_vm "$VM_NAME" "$IMAGE_NAME" "$VM_MEMORY" "$VM_NETWORK" "$VM_PROCESSOR" "$VM_SSH_KEY" "$IMAGE_USER" "$PRIVATE_SSH_KEY_PATH" "$VM_Creation" "$Communicate"
}

run "$@"
