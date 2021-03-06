#!/usr/bin/env bash

NAMENODE_FORMATTED_FLAG="/var/lib/hadoop/namenode-is-formatted"
NAMENODE_BOOTSTRAPSTANDBY_FLAG="/var/lib/hadoop/namenode-is-bootstrapStandby"

# Update core-site.xml
: ${CLUSTER_NAME:?"CLUSTER_NAME is required."}
: ${DFS_NAMESERVICES:?"DFS_NAMESERVICES is required."}
addConfig $CORE_SITE "fs.defaultFS" "hdfs://${DFS_NAMESERVICES}"
addConfig $CORE_SITE "fs.trash.interval" ${FS_TRASH_INTERVAL:=1440}
addConfig $CORE_SITE "fs.trash.checkpoint.interval" ${FS_TRASH_CHECKPOINT_INTERVAL:=0}
addConfig $CORE_SITE "ipc.client.connect.retry.interval" 6000
addConfig $CORE_SITE "ipc.client.connect.max.retries" 400


addConfig $CORE_SITE "io.compression.codecs" "org.apache.hadoop.io.compress.DefaultCodec,org.apache.hadoop.io.compress.SnappyCodec"

: ${HA_ZOOKEEPER_QUORUM:?"HA_ZOOKEEPER_QUORUM is required."}
addConfig $CORE_SITE "ha.zookeeper.quorum" $HA_ZOOKEEPER_QUORUM
addConfig $CORE_SITE "ha.zookeeper.parent-znode" /$CLUSTER_NAME

# Update hdfs-site.xml
addConfig $HDFS_SITE "dfs.namenode.datanode.registration.ip-hostname-check" "false"
addConfig $HDFS_SITE "dfs.permissions.superusergroup" "hadoop"
addConfig $HDFS_SITE "dfs.nameservices" $DFS_NAMESERVICES
addConfig $HDFS_SITE "dfs.ha.namenodes.${DFS_NAMESERVICES}" "nn1,nn2"



: ${DFS_NAMENODE_RPC_ADDRESS_NN1:?"DFS_NAMENODE_RPC_ADDRESS_NN1 is required."}
addConfig $HDFS_SITE "dfs.namenode.rpc-address.${DFS_NAMESERVICES}.nn1" $DFS_NAMENODE_RPC_ADDRESS_NN1

: ${DFS_NAMENODE_RPC_ADDRESS_NN2:?"DFS_NAMENODE_RPC_ADDRESS_NN2 is required."}
addConfig $HDFS_SITE "dfs.namenode.rpc-address.${DFS_NAMESERVICES}.nn2" $DFS_NAMENODE_RPC_ADDRESS_NN2

: ${DFS_NAMENODE_HTTP_ADDRESS_NN1:?"DFS_NAMENODE_HTTP_ADDRESS_NN1 is required."}
addConfig $HDFS_SITE "dfs.namenode.http-address.${DFS_NAMESERVICES}.nn1" $DFS_NAMENODE_HTTP_ADDRESS_NN1

: ${DFS_NAMENODE_HTTP_ADDRESS_NN2:?"DFS_NAMENODE_HTTP_ADDRESS_NN2 is required."}
addConfig $HDFS_SITE "dfs.namenode.http-address.${DFS_NAMESERVICES}.nn2" $DFS_NAMENODE_HTTP_ADDRESS_NN2

addConfig $HDFS_SITE "dfs.client.failover.proxy.provider.${DFS_NAMESERVICES}" "org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider"
addConfig $HDFS_SITE "dfs.namenode.name.dir" ${DFS_NAMENODE_NAME_DIR:="file:///var/lib/hadoop/name"}

: ${DFS_NAMENODE_SHARED_EDITS_DIR:?"DFS_NAMENODE_SHARED_EDITS_DIR is required."}
DFS_NAMENODE_SHARED_EDITS_DIR=${DFS_NAMENODE_SHARED_EDITS_DIR//","/";"}
addConfig $HDFS_SITE "dfs.namenode.shared.edits.dir" "qjournal://${DFS_NAMENODE_SHARED_EDITS_DIR}/${DFS_NAMESERVICES}"

addConfig $HDFS_SITE "dfs.ha.fencing.methods" "shell(/bin/true)"

addConfig $HDFS_SITE "dfs.ha.automatic-failover.enabled" "true"

# Create and set the data directories correctly
IFS=',' read -ra DFS_NAMENODE_NAME_DIRS <<< "$DFS_NAMENODE_NAME_DIR"
for i in "${DFS_NAMENODE_NAME_DIRS[@]}"; do

    if [[ $i == "file:///"* ]]; then
        path=${i/"file://"/""}
        mkdir -p $path
        chmod 700 $path
        chown -R hadoop:hadoop $path
    fi
done

IFS=',' read -ra HA_ZOOKEEPER_QUORUMS <<< "$HA_ZOOKEEPER_QUORUM"
num_zk=${#HA_ZOOKEEPER_QUORUMS[*]}

IFS=":" read -ra REMOTE_ADDR <<< "${HA_ZOOKEEPER_QUORUMS[$((RANDOM%num_zk))]}"

until $(nc -z -v -w5 ${REMOTE_ADDR[0]} ${REMOTE_ADDR[1]}); do
    echo "Waiting for zookeeper to be available..."
    sleep 2
done

# Format namenode
if [ "$ACTIVE" == "true" ]; then
    echo "Formatting zookeeper"
    su-exec hadoop $HADOOP_HOME/bin/hdfs zkfc -formatZK -nonInteractive

    if [ ! -f $NAMENODE_FORMATTED_FLAG ]; then
        echo "Formatting namenode..."
        su-exec hadoop $HADOOP_HOME/bin/hdfs namenode -format -nonInteractive -clusterId $CLUSTER_NAME
        su-exec hadoop touch $NAMENODE_FORMATTED_FLAG
    fi
fi

# Set this namenode as standby if required
if [ "$ACTIVE" == "true" ]; then
    echo "Starting namenode in active mode..."
else
    echo "Starting namenode in standby mode..."
    if [ ! -f $NAMENODE_BOOTSTRAPSTANDBY_FLAG ]; then
        echo "Bootstrap standby namenode..."
        su-exec hadoop $HADOOP_HOME/bin/hdfs namenode -bootstrapStandby
        su-exec hadoop touch $NAMENODE_BOOTSTRAPSTANDBY_FLAG
    fi
fi

trap 'kill %1; kill %2' SIGINT SIGTERM

su-exec hadoop $HADOOP_HOME/bin/hdfs --config $HADOOP_CONF_DIR namenode &

# Start the zkfc
su-exec hadoop $HADOOP_HOME/bin/hdfs --config $HADOOP_CONF_DIR zkfc &

# Wait for cluster to be ready
su-exec hadoop $HADOOP_HOME/bin/hdfs dfsadmin -safemode wait

# Create the /tmp directory if it doesn't exist
su-exec hadoop $HADOOP_HOME/bin/hadoop fs -test -d /tmp

if [ $? != 0 ] && [ "$ACTIVE" == "true" ]; then
    su-exec hadoop $HADOOP_HOME/bin/hadoop fs -mkdir /tmp
    su-exec hadoop $HADOOP_HOME/bin/hadoop fs -chmod -R 1777 /tmp
fi

# start nginx
mkdir /run/nginx
mkdir -p /var/tmp/nginx

NGINX_PORT=${NGINX_PORT:-"9090"}
sed -i "s/NGINX_PORT/${NGINX_PORT}/" /etc/nginx/conf.d/default.conf

cd ${HADOOP_HOME}/etc && tar -cvzf /var/lib/nginx/html/hadoop.conf.tar.gz hadoop
cd ${HADOOP_HOME}/lib && tar -cvzf /var/lib/nginx/html/hadoop.lib.native.tar.gz native

# /usr/sbin/nginx -g daemon off;
/usr/sbin/nginx

echo -e "\nInit has completed ..."
while true; do
    x=$(ps -ef | grep java | grep -v "grep" | wc -l)
    if [[ $x -eq 0 ]]; then
        echo "No Java processes is running, exit ...."
        exit 0
    fi
    sleep 30
done
