#!/usr/bin/env bash
# Copyright 2014-2017, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Shell Opts ----------------------------------------------------------------

set -e -u -x
set -o pipefail

## Functions -----------------------------------------------------------------

export BASE_DIR=${BASE_DIR:-"/opt/rpc-openstack"}
source ${BASE_DIR}/scripts/functions.sh

## Main ----------------------------------------------------------------------

if [[ "$DEPLOY_AIO" != "yes" ]] && [[ "$DEPLOY_HARDENING" != "yes" ]]; then
  echo "** DEPLOY_HARDENING should no longer be used **"
  echo "To disable security hardening, please add the following line to"
  echo "/etc/openstack_deploy/user_osa_variables_overrides.yml and then"
  echo "re-run this script:"
  echo ""
  echo "apply_security_hardening: false"
  exit 1
fi

# Check the openstack-ansible submodule status
check_submodule_status

# Bootstrap Ansible
source "$(dirname "${0}")/bootstrap-ansible.sh"

# bootstrap the AIO
if [[ "${DEPLOY_AIO}" == "yes" ]]; then

  # execute the AIO configuration bootstrap
  source "$(dirname "${0}")/bootstrap-aio.sh"

  # set the ansible inventory hostname to the host's name
  sed -i "s/aio1/$(hostname)/" /etc/openstack_deploy/openstack_user_config.yml
  sed -i "s/aio1/$(hostname)/" /etc/openstack_deploy/conf.d/*.yml

fi

# move OSA secrets to correct locations
if [[ ! -f /etc/openstack_deploy/user_osa_secrets.yml ]] && [[ -f /etc/openstack_deploy/user_secrets.yml ]]; then
  mv /etc/openstack_deploy/user_secrets.yml /etc/openstack_deploy/user_osa_secrets.yml
fi

# update the RPC-O secrets
bash ${BASE_DIR}/scripts/update-secrets.sh

# ensure all needed passwords and tokens are generated
${OA_DIR}/scripts/pw-token-gen.py --file /etc/openstack_deploy/user_osa_secrets.yml
${OA_DIR}/scripts/pw-token-gen.py --file $RPCD_SECRETS

# ensure that the ELK containers aren't created if they're not
# going to be used
# NOTE: this needs to happen before ansible/openstack-ansible is first run
if [[ "${DEPLOY_ELK}" != "yes" ]]; then
  rm -f /etc/openstack_deploy/env.d/{elasticsearch,logstash,kibana}.yml
fi

# Apply any patched files.
cd ${RPCD_DIR}/playbooks
openstack-ansible -i "localhost," patcher.yml

# set permissions and lay down overrides files
chmod 0440 /etc/openstack_deploy/user_*_defaults.yml
if [[ ! -f "$OA_OVERRIDES" ]]; then
  cp "${RPCD_DIR}"/etc/openstack_deploy/user_osa_variables_overrides.yml $OA_OVERRIDES
fi
if [[ ! -f "$RPCD_OVERRIDES" ]]; then
  cp "${RPCD_DIR}"/etc/openstack_deploy/user_rpco_variables_overrides.yml $RPCD_OVERRIDES
fi

# begin the openstack installation
if [[ "${DEPLOY_OA}" == "yes" ]]; then

  # This deploy script is also used for minor upgrades (within an openstack release)
  # Some versions of liberty deploy pip lockdown to the repo server, in order for an
  # upgrade to succeed the pip config must be removed so that repo builds have
  # access to external repos.
  # Issue tracking upstream fix: https://github.com/rcbops/rpc-openstack/issues/1028
  ansible repo_all -m file -a 'name=/root/.pip state=absent' 2>/dev/null ||:

  cd ${OA_DIR}/playbooks/

  # NOTE(mhayden): V-38642 must be skipped when using an apt repository with
  # unsigned/untrusted packages.
  # NOTE(mhayden): V-38660 halts the playbook run when it finds SNMP v1/2
  # configurations on a server. RPC has these configurations applied, so this
  # task must be skipped.
  if [[ ${UNAUTHENTICATED_APT} == "yes" && ${DEPLOY_HARDENING} == "yes" ]]; then
    run_ansible setup-hosts.yml --skip-tags=V-38462,V-38660
  else
    run_ansible setup-hosts.yml --skip-tags=V-38660
  fi

  if [[ "$DEPLOY_CEPH" == "yes" ]]; then
    pushd ${RPCD_DIR}/playbooks/
      run_ansible ceph-all.yml
    popd
  fi

  # setup the infrastructure
  run_ansible setup-infrastructure.yml

  # TODO(odyssey4me)
  # Remove this once https://review.openstack.org/422629 merges and is available for RPC-O
  if [ "${DEPLOY_AIO}" == "yes" ]; then
    ansible neutron_agent -m command \
                          -a '/sbin/iptables -t mangle -A POSTROUTING -p tcp --sport 80 -j CHECKSUM --checksum-fill'
    ansible neutron_agent -m command \
                          -a '/sbin/iptables -t mangle -A POSTROUTING -p tcp --sport 8000 -j CHECKSUM --checksum-fill'
    ansible neutron_agent -m shell \
                          -a 'DEBIAN_FRONTEND=noninteractive apt-get -y install iptables-persistent'
  fi

  # setup openstack
  run_ansible setup-openstack.yml

  if [[ "${DEPLOY_TEMPEST}" == "yes" ]]; then
    # Deploy tempest
    run_ansible os-tempest-install.yml
  fi

fi

# Begin the RPC installation
bash ${BASE_DIR}/scripts/deploy-rpc-playbooks.sh
