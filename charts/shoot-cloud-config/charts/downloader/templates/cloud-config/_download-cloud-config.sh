{{- define "shoot-cloud-config.cloud-config-downloader" -}}
#!/bin/bash -eu

SECRET_NAME="{{ required "secretName is required" .Values.secretName }}"

DIR_CLOUDCONFIG="/var/run/coreos"
DIR_CLOUDCONFIG_DOWNLOADER="/var/lib/cloud-config-downloader"
DIR_KUBELET="/var/lib/kubelet"

PATH_YAML2JSON="$DIR_CLOUDCONFIG_DOWNLOADER/yaml2json"
PATH_KUBECONFIG="$DIR_CLOUDCONFIG_DOWNLOADER/kubeconfig"
PATH_RESOURCEVERSION_CURRENT="$DIR_CLOUDCONFIG_DOWNLOADER/current_resourceversion"
PATH_RESOURCE_LAST_APPLIED="$DIR_CLOUDCONFIG_DOWNLOADER/last_applied_resourceversion"
PATH_CLOUDCONFIG="$DIR_CLOUDCONFIG/cloud_config.yml"

mkdir -p "$DIR_CLOUDCONFIG" "$DIR_KUBELET"

if [ ! -f "$PATH_YAML2JSON" ]; then
  curl -L "https://github.com/bronze1man/yaml2json/raw/master/builds/linux_amd64/yaml2json" -o "$PATH_YAML2JSON"
  chmod +x "$PATH_YAML2JSON"
fi

if ! CLOUD_CONFIG_SECRET="$(/bin/docker run \
  --rm \
  --net host \
  -v "$DIR_CLOUDCONFIG"/:"$DIR_CLOUDCONFIG" \
  -v "$DIR_CLOUDCONFIG_DOWNLOADER"/:"$DIR_CLOUDCONFIG_DOWNLOADER" \
  k8s.gcr.io/hyperkube:v1.9.2\
  kubectl --kubeconfig="$PATH_KUBECONFIG" --namespace=kube-system get secret "$SECRET_NAME" -o jsonpath='{.metadata.resourceVersion}{"\t"}{.data.cloudconfig}{"\t"}{.data.bootstrapToken}')"; then
  echo "Could not retrieve the cloud config secret with name $SECRET_NAME"
  exit 1
fi

echo $CLOUD_CONFIG_SECRET | awk '{print $1}' > "$PATH_RESOURCEVERSION_CURRENT"
echo $CLOUD_CONFIG_SECRET | awk '{print $2}' | base64 -d > "$PATH_CLOUDCONFIG"
BOOTSTRAP_TOKEN="$(echo $CLOUD_CONFIG_SECRET | awk '{print $3}' | base64 -d)"

if [ ! -f "$PATH_CLOUDCONFIG" ]; then
  echo "No cloud config file found at location $PATH_CLOUDCONFIG"
  exit 1
fi

if [[ ! -f "$DIR_KUBELET/kubeconfig-real" ]]; then
  CLUSTER_INFO="$("$PATH_YAML2JSON" < "$PATH_KUBECONFIG" | jq -r '.clusters[0].cluster')"
  CA_CRT="$(echo $CLUSTER_INFO | jq -r '."certificate-authority-data"')"
  SERVER="$(echo $CLUSTER_INFO | jq -r '.server')"

  cat <<EOF > "$DIR_KUBELET/kubeconfig-bootstrap"
---
apiVersion: v1
kind: Config
current-context: kubelet-bootstrap@default
clusters:
- cluster:
    certificate-authority-data: $CA_CRT
    server: $SERVER
  name: default
contexts:
- context:
    cluster: default
    user: kubelet-bootstrap
  name: kubelet-bootstrap@default
users:
- name: kubelet-bootstrap
  user:
    as-user-extra: {}
    token: $BOOTSTRAP_TOKEN
EOF

else
  rm -f "$DIR_KUBELET/kubeconfig-bootstrap"
fi

RESOURCEVERSION_CURRENT=0
RESOURCEVERSION_LAST_APPLIED=0

if [ -f "$PATH_RESOURCEVERSION_CURRENT" ]; then
  RESOURCEVERSION_CURRENT="$(cat $PATH_RESOURCEVERSION_CURRENT)"
fi
if [ -f "$PATH_RESOURCE_LAST_APPLIED" ]; then
  RESOURCEVERSION_LAST_APPLIED="$(cat $PATH_RESOURCE_LAST_APPLIED)"
fi

if [ "$RESOURCEVERSION_CURRENT" -gt "$RESOURCEVERSION_LAST_APPLIED" ]; then
  echo "Seen cloud config version $RESOURCEVERSION_CURRENT, applying it"
  if /usr/bin/coreos-cloudinit -from-file="$PATH_CLOUDCONFIG"; then
    echo "Successfully applied cloud config with resource version $RESOURCEVERSION_CURRENT"
    if [ "$RESOURCEVERSION_LAST_APPLIED" -ne "0" ]; then
      systemctl daemon-reload
      "$PATH_YAML2JSON" < "$PATH_CLOUDCONFIG" | jq -r '.coreos.units[] | .name' | xargs systemctl restart
      echo "Successfully restarted all our units."
    fi
    echo $RESOURCEVERSION_CURRENT > $PATH_RESOURCE_LAST_APPLIED
  fi
fi
{{- end -}}
