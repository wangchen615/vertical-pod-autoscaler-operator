#!/bin/bash

set -euo pipefail

function run_upstream_vpa_tests() {
  if $recommendationOnly
  then
    echo "recommendationOnly is enabled. Run the recommender e2e tests in upstream ..."
    pushd ${SCRIPT_ROOT}/e2e
    GO111MODULE=on go test -mod vendor ./v1/*go -v --test.timeout=60m --args --ginkgo.v=true --ginkgo.focus="\[VPA\] \[recommender\]" --ginkgo.skip="doesn't drop lower/upper after recommender's restart" --report-dir=/workspace/_artifacts --disable-log-dump
    V1_RESULT=$?
    popd
    echo "v1 recommender test result:" ${V1_RESULT}

    if [ $V1_RESULT -gt 0 ]; then
      echo "Tests failed"
      exit 1
    fi
  else
    echo "recommendationOnly is disabled. Run the full-vpa e2e tests in upstream ..."
    pushd ${SCRIPT_ROOT}/e2e
    GO111MODULE=on go test -mod vendor ./v1/*go -v --test.timeout=60m --args --ginkgo.v=true --ginkgo.focus="\[VPA\] \[full-vpa\]" --report-dir=/workspace/_artifacts --disable-log-dump
    V1_RESULT=$?
    popd
    echo "v1 full-vpa test result:" ${V1_RESULT}

    if [ $V1_RESULT -gt 0 ]; then
      echo "Tests failed"
      exit 1
    fi
  fi
}

function await_for_controllers() {
  local retries=${1:-10}
  while [ ${retries} -ge 0 ]; do
    recommenderReplicas=$(kubectl get deployment vpa-recommender-default -n openshift-vertical-pod-autoscaler -oyaml|yq ".status.replicas")
    if [[ "$recommenderReplicas" == "null" ]]; then
      recommenderReplicas=0
    fi

    admissionpluginReplicas=$(kubectl get deployment vpa-admission-plugin-default -n openshift-vertical-pod-autoscaler -oyaml|yq ".status.replicas")
    if [[ "$admissionpluginReplicas" == "null" ]]; then
      admissionpluginReplicas=0
    fi

    updaterReplicas=$(kubectl get deployment vpa-updater-default -n openshift-vertical-pod-autoscaler -oyaml|yq ".status.replicas")
    if [[ "$updaterReplicas" == "null" ]]; then
      updaterReplicas=0
    fi

    if ((${recommenderReplicas} >= 1)) && ((${admissionpluginReplicas} >= 1)) && ((${updaterReplicas} >= 1));
    then
      echo "all"
      return
    elif ((${recommenderReplicas} >= 1)) && ((${admissionpluginReplicas} == 0)) && ((${updaterReplicas} == 0));
    then
      echo "recommender"
      return
    fi
    retries=$((retries - 1))
    sleep 3
  done
  echo "unknown"
  return
}

WAIT_TIME=10
echo "Setting the default verticalpodautoscalercontroller with {\"spec\":{\"recommendationOnly\": true}}"
kubectl patch verticalpodautoscalercontroller default -n openshift-vertical-pod-autoscaler --type merge --patch '{"spec":{"recommendationOnly": true}}'
curstatus=$(await_for_controllers "$WAIT_TIME")
if [[ "$curstatus" == "recommender" ]];
then
  echo "Only recommender is running!"
else
  echo "error - only recommender should be running!"
  exit 1
fi

GOPATH="$(mktemp -d)"
export GOPATH
echo $GOPATH
AUTOSCALER_PKG="github.com/openshift/kubernetes-autoscaler"
RELEASE_VERSION="release-4.8"
echo "Get the github.com/openshift/kubernetes-autoscaler package!"
# GO111MODULE=off go get -u -d "${AUTOSCALER_PKG}/..."
mkdir -p ${GOPATH}/src/k8s.io
cd ${GOPATH}/src/k8s.io && git clone -b ${RELEASE_VERSION} --single-branch https://${AUTOSCALER_PKG}.git autoscaler

echo "Check the VerticalPodAutoScalerController configurations ..."
SCRIPT_ROOT=${GOPATH}/src/k8s.io/autoscaler/vertical-pod-autoscaler/

recommendationOnly=$(kubectl get VerticalPodAutoScalerController default -n openshift-vertical-pod-autoscaler -oyaml|yq ".spec.recommendationOnly" || false)
run_upstream_vpa_tests

kubectl patch verticalpodautoscalercontroller default -n openshift-vertical-pod-autoscaler --type merge --patch '{"spec":{"recommendationOnly": false}}'
curstatus=$(await_for_controllers "$WAIT_TIME")
if [[ "$curstatus" == "all" ]];
then
  echo "All controllers are running"
else
  echo "error - not all controllers are running!"
  exit 1
fi
recommendationOnly=$(kubectl get VerticalPodAutoScalerController default -n openshift-vertical-pod-autoscaler -oyaml|yq ".spec.recommendationOnly" || false)
run_upstream_vpa_tests