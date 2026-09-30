#!/bin/bash

set -euo pipefail
###############################################################################
# Configuration
###############################################################################

AD_DOMAIN="ad.palmmasasri.com"
AD_REALM="AD.PALMMASASRI.COM"

# AD attribute containing the user's SSH public key(s)
SSH_KEY_ATTRIBUTE="sshPublicKey"

# Linux defaults
AD_DEFAULT_SHELL="/bin/bash"
CACHE_CREDENTIALS="true"
USE_FULLY_QUALIFIED_NAMES="false"

# Packages required for AD/SSSD integration
PACKAGES=(
    sudo
    realmd
    adcli
    sssd
    sssd-ad
    sssd-tools
    libnss-sss
    libpam-sss
    samba-common-bin
    krb5-user
    packagekit
)

# if [[ -r /etc/os-release ]]; then
#     . /etc/os-release
# else
#     echo "ERROR: /etc/os-release not found."
#     exit 1
# fi
###############################################################################
# Helpers
###############################################################################

log() {
    echo
    echo "==> $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root."
    fi
}

###############################################################################
# Initial checks
###############################################################################

require_root

if ! command -v apt-get >/dev/null 2>&1; then
    die "This script expects an Ubuntu/Debian system with apt."
fi

log "Installing required packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y "${PACKAGES[@]}"

###############################################################################
# Normalize hostname
###############################################################################

CURRENT_HOSTNAME="$(hostname -s)"

if [[ "$(hostname -f)" != "${CURRENT_HOSTNAME}.${AD_DOMAIN}" ]]; then
    log "Setting FQDN hostname to ${CURRENT_HOSTNAME}.${AD_DOMAIN}..."
    sudo hostnamectl set-hostname "${CURRENT_HOSTNAME}.${AD_DOMAIN}"
fi

###############################################################################
# Discover AD domain
###############################################################################

log "Discovering Active Directory domain"

if ! realm discover "${AD_DOMAIN}"; then
    die "Unable to discover Active Directory domain ${AD_DOMAIN}."
fi

###############################################################################
# Join AD if necessary
###############################################################################

if realm list | grep -Eqi \
    "^[[:space:]]*domain-name:[[:space:]]*${AD_DOMAIN}[[:space:]]*$"; then

    log "System is already joined to ${AD_DOMAIN}"

else

    log "Joining ${AD_DOMAIN}"

    echo J4PdkDEeXsJX | realm join "${AD_DOMAIN}" -U svc_linux_join

fi

# ###############################################################################
# # Verify AD join
# ###############################################################################

# log "Verifying Active Directory join"

# # realm list indents domain-name, therefore the leading whitespace is
# # intentionally accepted here.
# if ! realm list | grep -Eqi \
#     "^[[:space:]]*domain-name:[[:space:]]*${AD_DOMAIN}[[:space:]]*$"; then

#     die "Domain join verification failed."

# fi

# # Perform an actual machine-account validation as well.
# if [[ "$SKIP_ADCLI_TESTJOIN" != true ]]; then
#     # Perform adcli testjoin health check
#     if ! adcli testjoin "$AD_DOMAIN"; then
#         die "AD machine account test failed."
#         exit 1
#     fi
# fi

# log "Active Directory join verified successfully"

###############################################################################
# Configure SSSD
###############################################################################

log "Configuring SSSD"

cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = ${AD_DOMAIN}
services = nss, pam, ssh


[domain/${AD_DOMAIN}]
id_provider = ad
auth_provider = ad
access_provider = simple
ad_domain = ${AD_DOMAIN}
krb5_realm = ${AD_REALM}
default_shell = ${AD_DEFAULT_SHELL}
cache_credentials = ${CACHE_CREDENTIALS}
use_fully_qualified_names = ${USE_FULLY_QUALIFIED_NAMES}
fallback_homedir = /home/%u
ldap_id_mapping = true
ldap_user_ssh_public_key = ${SSH_KEY_ATTRIBUTE}

simple_allow_groups = access_${CURRENT_HOSTNAME}
EOF

chmod 600 /etc/sssd/sssd.conf

###############################################################################
# Validate SSSD configuration
###############################################################################

log "Validating SSSD configuration"

if ! sssctl config-check; then
    die "SSSD configuration validation failed."
fi

###############################################################################
# Enable PAM/NSS integration
###############################################################################

log "Enabling SSSD PAM/NSS integration"

# pam-auth-update is the Ubuntu-supported way of enabling the SSSD PAM
# profiles and pam_mkhomedir.
#
# The --package option prevents unrelated PAM profiles from being changed.
pam-auth-update --package --enable mkhomedir

###############################################################################
# Configure SSH authorized keys through SSSD
###############################################################################

log "Configuring sshd for SSSD SSH public keys"

SSHD_CONFIG="/etc/ssh/sshd_config"

# Remove existing active instances of these directives so that the resulting
# configuration contains exactly one effective configuration.
sed -i \
    '/^[[:space:]]*AuthorizedKeysCommand[[:space:]]\+.*sss_ssh_authorizedkeys.*$/d' \
    "${SSHD_CONFIG}"

sed -i \
    '/^[[:space:]]*AuthorizedKeysCommandUser[[:space:]]\+nobody[[:space:]]*$/d' \
    "${SSHD_CONFIG}"

cat >> "${SSHD_CONFIG}" <<'EOF'

# Retrieve SSH public keys from Active Directory through SSSD.
AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
AuthorizedKeysCommandUser nobody
EOF
###############################################################################
# Configure sudoers for those with access to the server
###############################################################################

touch "/etc/sudoers.d/99-ad-integration"
cat > "/etc/sudoers.d/99-ad-integration" << EOF
%access_${CURRENT_HOSTNAME} ALL=(ALL) ALL
%access_${CURRENT_HOSTNAME} ALL=NOPASSWD: /usr/bin/sftp-server
EOF

###############################################################################
# Validate SSH configuration
###############################################################################

log "Validating sshd configuration"

if ! sshd -t; then
    die "sshd configuration validation failed. SSH service was NOT reloaded."
fi

###############################################################################
# Restart SSSD
###############################################################################

log "Restarting SSSD"

systemctl enable sssd
systemctl restart sssd

if ! systemctl is-active --quiet sssd; then
    die "SSSD failed to start."
fi

###############################################################################
# Reload SSH
###############################################################################

log "Reloading SSH"

systemctl reload ssh

###############################################################################
# Final status
###############################################################################

log "Installation completed successfully"

echo
echo "Active Directory : ${AD_DOMAIN}"
echo "Kerberos realm   : ${AD_REALM}"
echo "SSSD SSH mapping : ${SSH_KEY_ATTRIBUTE}"
echo "Home directory   : /home/<username>"
echo "Access Group     : access_${CURRENT_HOSTNAME}"
