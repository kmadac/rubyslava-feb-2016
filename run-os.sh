#!/bin/bash
# Integration test for neutron service
# Test runs mysql,memcached,keystone, glance, nova and neutron containers and checks whether neutron is running

GIT_REPO=172.27.10.10
RELEASE_REPO=172.27.9.130

create_keystone_db() {
    MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -pveryS3cr3t"
    $MYSQL_CMD -e "CREATE DATABASE keystone;"
    $MYSQL_CMD -e "CREATE USER 'keystone'@'%' IDENTIFIED BY 'veryS3cr3t';"
    $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' WITH GRANT OPTION;"
}

create_glance_db() {
    MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -pveryS3cr3t"
    $MYSQL_CMD -e "CREATE DATABASE glance;"
    $MYSQL_CMD -e "CREATE USER 'glance'@'%' IDENTIFIED BY 'veryS3cr3t';"
    $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' WITH GRANT OPTION;"
}

create_nova_db() {
    MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -pveryS3cr3t"
    $MYSQL_CMD -e "CREATE DATABASE nova;"
    $MYSQL_CMD -e "CREATE USER 'nova'@'%' IDENTIFIED BY 'veryS3cr3t';"
    $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' WITH GRANT OPTION;"
}

create_neutron_db() {
    MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -pveryS3cr3t"
    $MYSQL_CMD -e "CREATE DATABASE neutron;"
    $MYSQL_CMD -e "CREATE USER 'neutron'@'%' IDENTIFIED BY 'veryS3cr3t';"
    $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' WITH GRANT OPTION;"
}

wait_for_port() {
    local port="$1"
    local timeout=$2
    local counter=0
    echo "Wait till app is bound to port $port "
    while [[ $counter -lt $timeout ]]; do
        local counter=$[counter + 1]
        if [[ ! `ss -ntl4 | grep ":${port}"` ]]; then
            echo -n ". "
        else
            break
        fi
        sleep 1
    done

    if [[ $timeout -eq $counter ]]; then
        exit 1
    fi
}

cleanup() {
    echo "Clean up ..."
    docker stop galera
    docker stop memcached
    docker stop rabbitmq
    docker stop keystone
    docker stop glance
    docker stop nova-controller
    docker stop nova-compute
    docker stop neutron-controller
    docker stop neutron-compute
    docker stop horizon

    docker rm galera
    docker rm memcached
    docker rm rabbitmq
    docker rm keystone
    docker rm glance
    docker rm nova-controller
    docker rm nova-compute
    docker rm neutron-controller
    docker rm neutron-compute
    docker rm horizon
}

cleanup

##### Download/Build containers

# pull galera docker image
#get_docker_image_from_release galera http://${RELEASE_REPO}/docker-galera latest

# pull rabbitmq docker image
#get_docker_image_from_release rabbitmq http://${RELEASE_REPO}/docker-rabbitmq latest

# pull osmaster docker image
#get_docker_image_from_release osmaster http://${RELEASE_REPO}/docker-osmaster latest

# pull keystone image
#get_docker_image_from_release keystone http://${RELEASE_REPO}/docker-keystone latest

# pull glance image
#get_docker_image_from_release glance http://${RELEASE_REPO}/docker-glance latest

# pull osadmin docker image
#get_docker_image_from_release osadmin http://${RELEASE_REPO}/docker-osadmin latest

##### Start Containers

echo "Starting galera container ..."
GALERA_TAG=$(docker images | grep -w galera | head -n 1 | awk '{print $2}')
docker run -d --net=host -e INITIALIZE_CLUSTER=1 -e MYSQL_ROOT_PASS=veryS3cr3t -e WSREP_USER=wsrepuser -e WSREP_PASS=wsreppass -e DEBUG= --name galera galera:$GALERA_TAG

echo "Wait till galera is running ."
wait_for_port 3306 30

echo "Starting Memcached node (tokens caching) ..."
docker run -d --net=host -e DEBUG= --name memcached memcached

echo "Starting RabbitMQ container ..."
docker run -d --net=host -e DEBUG= --name rabbitmq rabbitmq

sleep 10 # wait a moment ...

# create databases
create_keystone_db
create_glance_db
create_nova_db
create_neutron_db

echo "Starting keystone container"
docker run -d --net=host -e DEBUG="true" -e DB_SYNC="true" --name keystone keystone:latest

echo "Wait till keystone is running ."

wait_for_port 5000 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 5000 (Keystone) not bounded!"
    exit $ret
fi

wait_for_port 35357 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 35357 (Keystone Admin) not bounded!"
    exit $ret
fi

echo "Starting glance container"
docker run -d --net=host -e DEBUG="true" -e DB_SYNC="true" --name glance glance:latest

echo "Starting nova-controller container"
docker run -d --net=host --privileged \
           -e DEBUG="true" \
           -e DB_SYNC="true" \
           -e NOVA_CONTROLLER="true" \
           --name nova-controller \
           nova:latest

wait_for_port 8774 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 8774 (Nova-Api) not bounded!"
    exit $ret
fi

wait_for_port 8775 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 8775 (Metadata) not bounded!"
    exit $ret
fi

wait_for_port 6082 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 6082 (spice html5proxy) not bounded!"
    exit $ret
fi

echo "Starting nova-compute container"
docker run -d --net=host \
           -e DEBUG="true" \
           -e NOVA_CONTROLLER="false" \
           --name nova-compute \
           nova:latest

echo "Starting neutron-controller container"
docker run -d --net=host --privileged \
           -e DEBUG="true" \
           -e DB_SYNC="true" \
           -e NEUTRON_CONTROLLER="true" \
           -v /var/lib/openvswitch:/var/lib/openvswitch \
           -v /var/run/openvswitch:/var/run/openvswitch \
           --name neutron-controller \
           neutron:latest

wait_for_port 9696 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 9696 (neutron server) not bounded!"
    exit $ret
fi

echo "Starting neutron-compute container"
docker run -d --net=host --privileged \
           -e DEBUG="true" \
           -e DB_SYNC="false" \
           -e NEUTRON_CONTROLLER="false" \
           -v /var/lib/openvswitch:/var/lib/openvswitch \
           -v /var/run/openvswitch:/var/run/openvswitch \
           --name neutron-compute \
           neutron:latest

echo "Starting horizon container"
docker run -d --net=host \
           -e DEBUG="true" \
           --name horizon \
           horizon:latest

##### Wait till underlying services are ready #####

wait_for_port 9191 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 9191 (Glance Registry) not bounded!"
    exit $ret
fi

wait_for_port 9292 60
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Port 9292 (Glance API) not bounded!"
    exit $ret
fi

# bootstrap openstack settings and upload image to glance
docker run --net=host osadmin /bin/bash -c ". /app/adminrc; bash /app/bootstrap.sh"
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Keystone bootstrap error ${ret}!"
    exit $ret
fi

docker run --net=host osadmin /bin/bash -c ". /app/userrc; openstack image create --container-format bare --disk-format qcow2 --file /app/cirros.img --public cirros"
ret=$?
if [ $ret -ne 0 ]; then
    echo "Error: Cirros image import error ${ret}!"
    exit $ret
fi
