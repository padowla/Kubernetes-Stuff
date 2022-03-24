#!/bin/bash

shopt -s expand_aliases

# exit when any command fails
set -e
# keep track of the last executed command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
# echo an error message before exiting
trap 'echo "\"${last_command}\" command failed with exit code $?."' EXIT

{
    export SERVICE_IP=10.104.0.2 #deve essere un cluster IP!
    export STORAGE_CLASS=default
    export NAMESPACE_ACR="connected-registry"
    export CONNECTION_STRING="ConnectedRegistryName=snreb00002acrsergnano;SyncTokenName=snreb00002acrsergnano;SyncTokenPassword=5y7fjJtpc77A418DXWYsYL0WIu88pCf/;ParentGatewayEndpoint=snreb00002acr.westeurope.data.azurecr.io;ParentEndpointProtocol=https"
    export ENDPOINT1_REGISTRY_AZURE="snreb00002acr.westeurope.data.azurecr.io"
    export ENDPOINT2_REGISTRY_AZURE="snreb00002acr.azurecr.io"
    export DOCKER_USERNAME=test-pull-token
    export DOCKER_PASSWORD=qU5FxppX/QmlrpjNC=nBxOQcJh=52pVd
    export KUBECONFIG=/root/.kube/config_prod
    export CA_PATH="./certs/ca.crt"
    export KEY_PATH="./certs/cert.key"
    export LOG_FILENAME="log-acr-prod.txt"


    printf "\n\n================================== Env variables ==================================\n\n"
    echo "KUBECONFIG: ${KUBECONFIG}"
    echo "SERVICE IP ACR: ${SERVICE_IP}";
    echo "CONNECTION STRING: ${CONNECTION_STRING}"
    echo "ENDPOINT REGISTRY AZURE: ${ENDPOINT_REGISTRY_AZURE}"
    echo "NAMESPACE del connected registry: ${NAMESPACE_ACR}"
    echo "CA_PATH: ${CA_PATH}"
    echo "KEY_PATH: ${KEY_PATH}"
    echo "DOCKER USERNAME per deploy di test: ${DOCKER_USERNAME}"
    echo "DOCKER PASSWORD per deploy di test: ${DOCKER_PASSWORD}"
    printf "=======================================================================================\n\n"

    #Controllo se l'utente corrente è root
    if [ $EUID -ne 0 ]; then
        echo "This script should be run as root." > /dev/stderr
        exit 1
    fi


    while true; do
        read -r -p "Are the variables correct? (Yy/Nn): " answer
        case $answer in
            [Yy]* ) break;;
            [Nn]* ) exit 1;;
            * ) echo "Please answer Y or N.";;
        esac
    done
    
    ##Creazione del certificato
    printf "\n\n(+) Creation of certificate...\n\n"
    openssl req -newkey rsa:4096 -nodes -sha256 -keyout ./certs/cert.key -x509 -days 365 -out ${CA_PATH} -addext "subjectAltName = IP:${SERVICE_IP}"
    printf "\n\n================= Done =================\n\n"

    ##Export del certificato e della chiave
    printf "\n\n================================== Certificate ==================================\n\n"
    export TLS_CRT=$(cat ${CA_PATH} | base64 -w0)
    echo "${TLS_CRT}"
    printf "\n\n+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n\n"
    printf "\n\n================================== Key ==================================\n\n"
    export TLS_KEY=$(cat ${KEY_PATH} | base64 -w0)
    echo "${TLS_KEY}"
    printf "\n\n+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n\n"


    ##Installazione di kubectl se assente
    if ! command -v kubectl &> /dev/null
    then
        printf "\n\n(+) Installation of kubectl...\n\n"
        #download del binario
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        #Download del checksum
        curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
        #Validazione del binario
        echo "$(<kubectl.sha256)  kubectl" | sha256sum --check
        #installazione
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        #verifica della installazione
        kubectl version --client
        printf "\n\n================= Done =================\n\n"        
    else
        printf "\n\n(+) Verify kubectl and cluster status...\n\n"
        kubectl cluster-info
        printf "\n\n================= Done =================\n\n"
    fi



    #Installazione di helm (viene installata la versione 3.6.3 in quanto richiesta per il connected registry)
    printf "\n\n(+) Installation of helm 3.6.3-1\n\n"
    curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
    sudo apt-get install apt-transport-https --yes
    echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt-get update
    sudo apt-get install helm=3.6.3-1 #versione esatta per l'installazione dell'azure connected registry
    printf "\n\n================= Done =================\n\n"

    #Verifica raggiungibilità registry cloud
    printf "\n\n(+) Test DNS resolution registry on Azure and connectivity... \n\n"
    nslookup ${ENDPOINT1_REGISTRY_AZURE}
    nslookup ${ENDPOINT2_REGISTRY_AZURE}
    if [[ $(curl -k --user snreb00002acr:JGcUSDkKTO5b33s7b//JtImkoEcDHxxo -X GET https://snreb00002acr.azurecr.io/v2/_catalog) != *repo* ]]; then 
        echo "Registry on Cloud Azure Not Reachable!!"
        exit 1;
    else
        printf "\n\n(v) Test completed succesfully \n\n"
        printf "\n\n================= Done =================\n\n"
    fi


    #Deploy del registry tramite helm
    printf "\n\n(+) Deploy of connected registry\n\n"
    helm upgrade --namespace ${NAMESPACE_ACR} --create-namespace --install --set connectionString=${CONNECTION_STRING} --set service.clusterIP=${SERVICE_IP}  --set pvc.storageClassName=${STORAGE_CLASS} --set image="mcr.microsoft.com/acr/connected-registry:0.6.0" --set tls.crt=$TLS_CRT --set tls.key=$TLS_KEY connected-registry ./connected-registry
    printf "\n\n================= Done =================\n\n"

    kubectl create secret docker-registry regcredtest --docker-server=${SERVICE_IP}:443 --docker-username=${DOCKER_USERNAME} --docker-password=${DOCKER_PASSWORD} --docker-email=test@email.com --dry-run=client -o yaml | kubectl apply -f -

    #Listato dei nodi del cluster
    printf "\n\n(i) Nodes of AKS cluster:\n\n"
    kubectl get nodes -o wide
    printf "\n\n================= Done =================\n\n"

    #Comandi da eseguire su ogni nodo
    printf "\n\n(i) Executes following commands on each node of AKS cluster:\n\n"
    printf "1) $ ssh -i <chiave rsa nodo> clouduser@<ip nodo> sudo mkdir -p /etc/containerd/certs.d/${SERVICE_IP}:443 \n"
    printf "2) $ scp -i <chiave rsa nodo> ca.crt clouduser@<ip nodo>:/home/clouduser/ca.crt \n"
    printf "3) $ ssh -i <chiave rsa nodo> clouduser@<ip nodo> sudo mv /home/clouduser/ca.crt /etc/containerd/certs.d/${SERVICE_IP}:443\n"
    printf "4) $ ssh -i <chiave rsa nodo> clouduser@<ip nodo> sudo ls /etc/containerd/certs.d/${SERVICE_IP}:443\n"
    printf "5) $ ssh -i <chiave rsa nodo> clouduser@<ip nodo>\n"
    printf "6) $ sudo nano /etc/containerd/config.toml\n"
    printf "\n-----------------------------------------------------------------------------------\n"
    cat << EOF
version = 2
[plugins]
[plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "ecpacr.azurecr.io/pause:3.4.1"
[plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
[plugins."io.containerd.grpc.v1.cri".registry.configs."${SERVICE_IP}:443".tls]
    ca_file   = "/etc/containerd/certs.d/${SERVICE_IP}:443/ca.crt"
EOF
    printf "\n-----------------------------------------------------------------------------------\n"

    printf "7) $ sudo systemctl restart containerd\n"


} | tee ${LOG_FILENAME}