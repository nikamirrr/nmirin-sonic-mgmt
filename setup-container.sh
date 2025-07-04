#!/bin/bash

declare -r SCRIPT_NAME="$(basename "${0}")"
declare -r SCRIPT_PATH="$(readlink -f "${0}")"
declare -r SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

declare -r DOCKER_REGISTRY="sonicdev-microsoft.azurecr.io:443"
declare -r DOCKER_SONIC_MGMT="docker-sonic-mgmt:latest"
declare -r LOCAL_IMAGE_NAME="docker-sonic-mgmt-$(echo "${USER}" | tr '[:upper:]' '[:lower:]')"
declare -r LOCAL_IMAGE_TAG="master"
declare -r LOCAL_IMAGE="${LOCAL_IMAGE_NAME}:${LOCAL_IMAGE_TAG}"

declare -r ROOT_PASS="root"
declare -r USER_PASS="12345"

declare -r HOST_DGNAME="docker"
declare -r HOST_DGID="$(getent group | grep docker | awk -F: '{print $3}')"

declare -r HOST_GID="$(id -g)"
declare -r HOST_UID="$(id -u)"

declare -r ROOT_UID="0"

declare -r YES_PARAM="yes"
declare -r NO_PARAM="no"

declare -r EXIT_SUCCESS="0"
declare -r EXIT_FAILURE="1"

declare -r VERBOSE_ERROR="1"
declare -r VERBOSE_NOTICE="3"
declare -r VERBOSE_INFO="4"

declare -r VERBOSE_MAX="${VERBOSE_INFO}"
declare -r VERBOSE_MIN="${VERBOSE_ERROR}"

declare EXISTING_CONTAINER_NAME=""

#
# Arguments -----------------------------------------------------------------------------------------------------------
#

ENV_VARS=""
CONTAINER_NAME=""
IMAGE_ID=""
LINK_DIR=""
MOUNT_POINTS="-v \"/var/run/docker.sock:/var/run/docker.sock:rslave\""
PUBLISH_PORTS=""
FORCE_REMOVAL="${NO_PARAM}"
VERBOSE_LEVEL="${VERBOSE_MIN}"
SILENT_HOOK="&> /dev/null"

# Sonic-mgmt remote debug feature
DEBUG_PORT_START_RANGE=50000
DEBUG_PORT_END_RANGE=60000
DEFAULT_LOCK_FOLDER="/tmp/sonic-mgmt-locks/"

#
# Functions -----------------------------------------------------------------------------------------------------------
#

function log_error() {
    if [[ "${VERBOSE_LEVEL}" -ge "${VERBOSE_ERROR}" ]]; then
        echo "ERROR: $*"
    fi
}

function log_notice() {
    if [[ "${VERBOSE_LEVEL}" -ge "${VERBOSE_NOTICE}" ]]; then
        echo "NOTICE: $*"
    fi
}

function log_info() {
    if [[ "${VERBOSE_LEVEL}" -ge "${VERBOSE_INFO}" ]]; then
        echo "INFO: $*"
    fi
}

function exit_failure() {
    if [[ "${VERBOSE_LEVEL}" -ge "${VERBOSE_ERROR}" ]]; then
        echo
        log_error "$@"
        echo
    fi

    exit "${EXIT_FAILURE}"
}

function exit_success() {
    if [[ "${VERBOSE_LEVEL}" -ge "${VERBOSE_INFO}" ]]; then
        echo
        log_info "$@"
        echo
    fi

    exit "${EXIT_SUCCESS}"
}

function show_help_and_exit() {
    echo "Usage ./${SCRIPT_NAME} [OPTIONS]"
    echo
    echo "Mandatory options:"
    echo "  -n <container_name>  set the name of the Docker container"
    echo
    echo "Other options:"
    echo "  -e <VAR=value>      set environment variable inside the container (can be used multiple times)"
    echo "  -i <image_id>        specify Docker image to use. This can be an image ID (hashed value) or an image name."
    echo "                       If no value is provided, defaults to the following images in the specified order:"
    echo "                         1. The local image named \"docker-sonic-mgmt\""
    echo "                         2. The local image named \"sonicdev-microsoft.azurecr.io:443/docker-sonic-mgmt\""
    echo "                         3. The remote image at \"sonicdev-microsoft.azurecr.io:443/docker-sonic-mgmt\""
    echo "  -d <directory>       specify directory inside container to bind mount to sonic-mgmt root (default: \"/var/src\")"
    echo "  -m <mount_point>     specify directory to bind mount to container"
    echo "  -p <port>            publish container port to the host"
    echo "  -f                   automatically remove the container when it exits"
    echo "  -v                   explain what is being done"
    echo "  -x                   show execution details"
    echo "  -h                   display this help and exit"
    echo "  --enable-debug       enable debug mode"
    echo
    echo "Examples:"
    echo "  ./${SCRIPT_NAME} -n sonic-mgmt-${USER}_master"
    echo "  ./${SCRIPT_NAME} -n sonic-mgmt-${USER}_master -i sonicdev-microsoft.azurecr.io:443/docker-sonic-mgmt:latest"
    echo "  ./${SCRIPT_NAME} -n sonic-mgmt-${USER}_master -d /var/src"
    echo "  ./${SCRIPT_NAME} -n sonic-mgmt-${USER}_master -m /my/working/dir"
    echo "  ./${SCRIPT_NAME} -n sonic-mgmt-${USER}_master -p 192.0.2.1:8080:80/tcp"
    echo "  ./${SCRIPT_NAME} -n sonic-mgmt-${USER}_master --enable-debug"
    echo "  ./${SCRIPT_NAME} -h"
    echo
    exit ${1}
}

function show_local_container_login() {
    CONTAINER_EXEC_CMD="docker exec --user root \"${CONTAINER_NAME}\""
    CONTAINER_INTF_CMD="bash -c \"ip -4 route ls | grep 'default' | grep -Po '(?<=dev )(\S+)'\""
    CONTAINER_INTF="$(eval "${CONTAINER_EXEC_CMD} ${CONTAINER_INTF_CMD}")"
    CONTAINER_IPV4_CMD="bash -c \"ip -4 addr show dev \"${CONTAINER_INTF}\" | grep 'inet' | awk '{print \\\$2}' | cut -d'/' -f1\""
    CONTAINER_IPV4="$(eval "${CONTAINER_EXEC_CMD} ${CONTAINER_IPV4_CMD}")"

    echo "******************************************************************************"
    echo "EXEC: docker exec --user ${USER} -ti ${CONTAINER_NAME} bash"
    echo "SSH:  ssh -i ~/.ssh/id_rsa_docker_sonic_mgmt ${USER}@${CONTAINER_IPV4}"
    echo "******************************************************************************"

    if [[ -n ${SELECTED_DEBUG_PORT} ]]; then
        echo
        echo "*********************************[IMPORTANT]*********************************"
        echo "DEBUG PORT: $SELECTED_DEBUG_PORT"
        echo "Please use the above debug port in your vscode extensions"
        echo "When running the test, add --enable-debug to the end of your ./run_tests.sh to use"
        echo "You can check which port was assigned to you again by running 'docker ps' and search for your container"
        echo "*********************************[IMPORTANT]*********************************"
    fi
}

function pull_sonic_mgmt_docker_image() {
    if [[ -z "${IMAGE_ID}" ]]; then
        DOCKER_IMAGES_CMD="docker images --format \"{{.Repository}}:{{.Tag}}\""
        DOCKER_PULL_CMD="docker pull \"${DOCKER_REGISTRY}/${DOCKER_SONIC_MGMT}\""

        if eval "${DOCKER_IMAGES_CMD}" | grep -q "^${DOCKER_SONIC_MGMT}:latest$"; then
            IMAGE_ID="${DOCKER_SONIC_MGMT}"
        elif eval "${DOCKER_IMAGES_CMD}" | grep -q "^${DOCKER_REGISTRY}/${DOCKER_SONIC_MGMT}:latest$"; then
            IMAGE_ID="${DOCKER_REGISTRY}/${DOCKER_SONIC_MGMT}"
        elif log_info "pulling docker image from a registry ..." && eval "${DOCKER_PULL_CMD}"; then
            IMAGE_ID="${DOCKER_REGISTRY}/${DOCKER_SONIC_MGMT}"
        else
            exit_failure "unable to find a usable default docker image, please specify one manually"
        fi

        log_notice "using default docker image: ${IMAGE_ID}"
    fi
}

function setup_local_image() {
    AUTHKEY_FILE="${HOME}/.ssh/authorized_keys"
    PRIVKEY_FILE="${HOME}/.ssh/id_rsa_docker_sonic_mgmt"
    PUBKEY_FILE="${HOME}/.ssh/id_rsa_docker_sonic_mgmt.pub"

    if [[ ! -f "${PRIVKEY_FILE}" ]]; then
        log_info "generate SSH key pair: $(basename "${PRIVKEY_FILE}")/$(basename "${PUBKEY_FILE}")"
        ssh-keygen -t rsa -q -N "" -f "${PRIVKEY_FILE}" || \
        exit_failure "failed to generate SSH key pair: $(basename "${PRIVKEY_FILE}")/$(basename "${PUBKEY_FILE}")"
    fi

    log_info "read SSH public key: ${PUBKEY_FILE}"
    SSH_PUBKEY="$(cat "${PUBKEY_FILE}")" || \
    exit_failure "failed to read public SSH key: ${PUBKEY_FILE}"

    if [[ -f "${AUTHKEY_FILE}" ]]; then
        grep -q "${SSH_PUBKEY}" "${AUTHKEY_FILE}" || echo "${SSH_PUBKEY}" >> "${AUTHKEY_FILE}"
    else
        echo "${SSH_PUBKEY}" > "${AUTHKEY_FILE}"
        chmod 0644 "${AUTHKEY_FILE}"
    fi

    TMP_DIR="$(mktemp -d)"
    log_info "setup a temporary dir: ${TMP_DIR}"

    log_info "copy SSH key pair: $(basename "${PRIVKEY_FILE}")/$(basename "${PUBKEY_FILE}")"
    eval "cp -fv \"${PRIVKEY_FILE}\" \"${TMP_DIR}/id_rsa\" ${SILENT_HOOK}"
    eval "cp -fv \"${PUBKEY_FILE}\" \"${TMP_DIR}/id_rsa.pub\" ${SILENT_HOOK}"

    log_info "prepare a Dockerfile template: ${TMP_DIR}/Dockerfile.j2"
    cat <<'EOF' > "${TMP_DIR}/Dockerfile.j2"
FROM {{ IMAGE_ID }}

USER root

# Group configuration
RUN if getent group {{ GROUP_NAME }}; \
then groupmod -o -g {{ GROUP_ID }} {{ GROUP_NAME }}; \
else groupadd -o -g {{ GROUP_ID }} {{ GROUP_NAME }}; \
fi

# User configuration
RUN if getent passwd {{ USER_NAME }}; \
# Usermod will hang when user_id is large (https://github.com/moby/moby/issues/5419), and it can not work around this issue itself.
# So, we first delete the user and use `useradd -l` to work around this issue.
#then usermod -o -g {{ GROUP_ID }} -u {{ USER_ID }} -m -d /home/{{ USER_NAME }} {{ USER_NAME }}; \
then userdel {{ USER_NAME }}; \
fi
RUN useradd -o -l -g {{ GROUP_ID }} -u {{ USER_ID }} -m -d /home/{{ USER_NAME }} -s /bin/bash {{ USER_NAME }};

# Docker configuration
RUN if getent group {{ DGROUP_NAME }}; \
then groupmod -o -g {{ DGROUP_ID }} {{ DGROUP_NAME }}; \
else groupadd -o -g {{ DGROUP_ID }} {{ DGROUP_NAME }}; \
fi

# Environment configuration, skip python virtual environments
RUN if [ '{{ USER_NAME }}' != 'AzDevOps' ]; then \
/bin/bash -O extglob -c 'cp -a -f /var/AzDevOps/!(env-*) /home/{{ USER_NAME }}/'; \
for hidden_stuff in '.profile .local .ssh'; do \
/bin/bash -c 'cp -a -f /var/AzDevOps/$hidden_stuff /home/{{ USER_NAME }}/ || true'; done \
fi

# Permissions configuration
RUN usermod -a -G sudo {{ USER_NAME }}
RUN usermod -a -G {{ DGROUP_NAME }} {{ USER_NAME }}
RUN echo '{{ USER_NAME }} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/{{ USER_NAME }}
RUN chmod 0440 /etc/sudoers.d/{{ USER_NAME }}
RUN chown -R '{{ USER_ID }}:{{ GROUP_ID }}' /home/{{ USER_NAME }}

# SSH/PASS configuration
RUN sed -i -E 's/^#?PermitRootLogin.*$/PermitRootLogin yes/g' /etc/ssh/sshd_config
RUN echo 'root:{{ ROOT_PASS }}' | chpasswd
RUN echo '{{ USER_NAME }}:{{ USER_PASS }}' | chpasswd

USER {{ USER_NAME }}

ENV HOME=/home/{{ USER_NAME }}
ENV USER={{ USER_NAME }}

# Passwordless SSH access
COPY --chown={{ USER_ID }}:{{ GROUP_ID }} id_rsa id_rsa.pub ${HOME}/.ssh/
RUN chmod 0700 ${HOME}/.ssh
RUN chmod 0600 ${HOME}/.ssh/id_rsa
RUN chmod 0644 ${HOME}/.ssh/id_rsa.pub
RUN cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys
RUN chmod 0600 ${HOME}/.ssh/authorized_keys

WORKDIR ${HOME}

# Setup python3 virtual env if some conditions are met:
# 1. pytest is not globally installed. If pytest is gloablly installed, this assumes that all the packages in
#    the python3 virtual env are installed globally. No need to create python3 virtual env.
# 2. The user is not AzDevOps. By default python3 virtual env is installed for AzDevOps user.
#    No need to install it again when current user is AzDevOps.
# 3. The python3 virtual env is not installed for AzDevOps. Then, it is not required for other users either.
RUN if ! pip3 list | grep -c pytest >/dev/null && \
[ '{{ USER_NAME }}' != 'AzDevOps' ] && \
[ -d /var/AzDevOps/env-python3 ]; then \
/bin/bash -c 'python3 -m venv ${HOME}/env-python3'; \
/bin/bash -c '${HOME}/env-python3/bin/pip install pip --upgrade'; \
/bin/bash -c '${HOME}/env-python3/bin/pip install wheel'; \
/bin/bash -c '${HOME}/env-python3/bin/pip install $(/var/AzDevOps/env-python3/bin/pip freeze | grep -vE "distro|PyGObject|python-apt|unattended-upgrades|dbus-python")'; \
fi

# Remote debug port setup
{% if SONIC_MGMT_DEBUG_PORT %}
ENV SONIC_MGMT_DEBUG_PORT={{ SONIC_MGMT_DEBUG_PORT }}
{% endif %}
EOF

    log_info "prepare an environment file: ${TMP_DIR}/data.env"
    cat <<EOF > "${TMP_DIR}/data.env"
IMAGE_ID=${IMAGE_ID}
DGROUP_NAME=${HOST_DGNAME}
DGROUP_ID=${HOST_DGID}
GROUP_ID=${HOST_GID}
USER_ID=${HOST_UID}
GROUP_NAME=${USER}
USER_NAME=${USER}
USER_PASS=${USER_PASS}
ROOT_PASS=${ROOT_PASS}
SONIC_MGMT_DEBUG_PORT=${SELECTED_DEBUG_PORT}
EOF

    log_info "generate a Dockerfile: ${TMP_DIR}/Dockerfile"
    j2 -o "${TMP_DIR}/Dockerfile" "${TMP_DIR}/Dockerfile.j2" "${TMP_DIR}/data.env" || \
    log_error "failed to generate a Dockerfile: ${TMP_DIR}/Dockerfile"

    log_info "building docker image from ${TMP_DIR}: ${LOCAL_IMAGE} ..."
    build_args=""
    if [[ -n ${http_proxy} ]]; then
        build_args="--build-arg http_proxy=${http_proxy}"
    fi
    if [[ -n ${https_proxy} ]]; then
        build_args="${build_args} --build-arg https_proxy=${https_proxy}"
    fi
    eval "docker build -t \"${LOCAL_IMAGE}\" \"${TMP_DIR}\" ${SILENT_HOOK} ${build_args}" || \
    log_error "failed to build docker image: ${LOCAL_IMAGE}"

    log_info "cleanup a temporary dir: ${TMP_DIR}"
    rm -rf "${TMP_DIR}"

    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${LOCAL_IMAGE}$"; then
        exit_failure "failed to build docker image: ${LOCAL_IMAGE}"
    fi
}

function container_exists() {
    container_id=`docker ps --all --filter name=^$CONTAINER_NAME\$ --format '{{.ID}}'`
    count=`echo $container_id | wc -w`
    return $count
}

function get_existing_container() {
    img_id=${IMAGE_ID}
    if [ -z ${img_id} ]
    then
        img_id=${LOCAL_IMAGE}
    fi
    container_id=`docker container ls --all --filter=ancestor=${img_id} --format '{{.ID}}'`
    count=`echo $container_id | wc -w`
    case $count in
        0)
            EXISTING_CONTAINER_NAME=""
            ;;
        1)
            container_name=`docker inspect $container_id --format '{{.Name}}'`
            if [[ $container_name == /* ]]
            then
                container_name="${container_name:1}"
            fi
            EXISTING_CONTAINER_NAME=${container_name}
            ;;
        *)
            echo "Multiple container IDs found: ${container_id}"
            EXISTING_CONTAINER_NAME=""
            ;;
    esac
}

function start_local_container() {

    container_exists
    local exists=$?
    if [ $exists -eq 1 ]
    then
        log_info "starting existing container ${CONTAINER_NAME} ..."
        docker start ${CONTAINER_NAME}
    else
        log_info "creating a container: ${CONTAINER_NAME} ..."
        eval "docker run -d -t ${PUBLISH_PORTS} ${ENV_VARS} -h ${CONTAINER_NAME} \
        -v \"$(dirname "${SCRIPT_DIR}"):${LINK_DIR}:rslave\" ${MOUNT_POINTS} \
        --name \"${CONTAINER_NAME}\" \"${LOCAL_IMAGE}\" /bin/bash ${SILENT_HOOK}" || \
        exit_failure "failed to start a container: ${CONTAINER_NAME}"
    fi

    eval "docker exec --user root \"${CONTAINER_NAME}\" \
    bash -c \"service ssh restart\" ${SILENT_HOOK}" || \
    exit_failure "failed to start SSH service"

    log_info "verifying UID and GID in container matches host"
    CONTAINER_GID="$(docker exec "${CONTAINER_NAME}" bash -c "id ${USER} -g")"
    CONTAINER_UID="$(docker exec "${CONTAINER_NAME}" bash -c "id ${USER} -u")"

    if [[ "${HOST_GID}" != "${CONTAINER_GID}" ]]; then
        exit_failure "group ID mismatch between host and container"
    fi

    if [[ "${HOST_UID}" != "${CONTAINER_UID}" ]]; then
        exit_failure "user ID mismatch between host and container"
    fi
}

function parse_arguments() {

    if [[ -z "${CONTAINER_NAME}" ]]; then
        get_existing_container
        if [ -z $EXISTING_CONTAINER_NAME ]
        then
            exit_failure "container name is not set."
        else
            exit_failure "found existing container (\"docker start $EXISTING_CONTAINER_NAME\")"
        fi
    else
        # If container name is over 64 characters, container will not be able to start due to hostname limitation
        container_name_len=${#CONTAINER_NAME}
        if [ "$container_name_len" -gt "64" ]; then
            exit_failure "Length of supplied container name exceeds 64 characters (currently $container_name_len chars)"
        fi
    fi

    if [[ -z "${LINK_DIR}" ]]; then
        LINK_DIR="/var/src"
        log_notice "using default bind mount directory: ${LINK_DIR}"
    fi
}

function find_debug_port() {
    mkdir -p "$DEFAULT_LOCK_FOLDER"
    for port in $(seq $DEBUG_PORT_START_RANGE $DEBUG_PORT_END_RANGE); do
        if ! ss -tuln | grep -q ":$port\b" && mkdir $DEFAULT_LOCK_FOLDER/$port.lock 2>/dev/null; then
            trap "rm -rf $DEFAULT_LOCK_FOLDER/$port.lock" EXIT # Remove the port.lock file when done
            SELECTED_DEBUG_PORT=$port
            return 0
        fi
    done
    return 1
}


ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--enable-debug" ]]; then
        ENABLE_DEBUG=1
    else
        ARGS+=("$arg")
    fi
done

set -- "${ARGS[@]}"
#
# Script --------------------------------------------------------------------------------------------------------------
#

if [[ $# -eq 0 ]]; then
    show_help_and_exit "${EXIT_SUCCESS}"
fi

while getopts "e:n:i:d:m:p:fvxh" opt; do
    case "${opt}" in
        n )
            CONTAINER_NAME="${OPTARG}"
            ;;
        e )
            ENV_VARS+=" -e ${OPTARG}"
            ;;
        i )
            IMAGE_ID="${OPTARG}"
            ;;
        d )
            LINK_DIR="${OPTARG}"
            ;;
        m )
            MOUNT_POINTS+=" -v \"${OPTARG}:${OPTARG}:rslave\""
            ;;
        p )
            PUBLISH_PORTS+=" -p \"${OPTARG}\""
            ;;
        f )
            FORCE_REMOVAL="${YES_PARAM}"
            ;;
        v )
            VERBOSE_LEVEL="${VERBOSE_MAX}"
            SILENT_HOOK=""
            ;;
        x )
            set -x
            ;;
        h )
            show_help_and_exit "${EXIT_SUCCESS}"
            ;;
        * )
            show_help_and_exit "${EXIT_FAILURE}"
            ;;
    esac
done

if [[ "$ENABLE_DEBUG" -eq 1 ]]; then
    find_debug_port
    if [[ -n "$SELECTED_DEBUG_PORT" ]]; then
        PUBLISH_PORTS+=" -p \"$SELECTED_DEBUG_PORT:$SELECTED_DEBUG_PORT\""
    else
        echo "FAILURE: Cannot find an eligible debug port within the range [$DEBUG_PORT_START_RANGE, $DEBUG_PORT_END_RANGE]"
        echo "Please re-run without --enable-debug option."
        exit 1
    fi
fi

parse_arguments

if [[ "$(id -u)" = "${ROOT_UID}" ]]; then
    exit_failure "run as regular user!"
fi

if ! docker info &> /dev/null; then
    exit_failure "unable to access Docker daemon: make sure ${USER} is a member of the docker group"
fi

if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    if [[ "${FORCE_REMOVAL}" = "${YES_PARAM}" ]]; then
        log_notice "removing existing container as requested: ${CONTAINER_NAME}"
        eval "docker rm -f \"${CONTAINER_NAME}\" ${SILENT_HOOK}"
    else
        show_local_container_login
        exit_success "container is already exists: ${CONTAINER_NAME}"
    fi
fi

if ! which j2 &> /dev/null; then
    exit_failure "missing Jinja2 templates support: make sure j2cli package is installed"
fi

pull_sonic_mgmt_docker_image
setup_local_image
start_local_container
show_local_container_login

exit_success "sonic-mgmt configuration is done!"
