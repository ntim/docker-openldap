#!/bin/bash -eux

addormodify() {
    local substitutions='${LDAPBASE} ${LDAP_BACKEND} ${LDAP_DOMAIN}'
    if grep -q changetype $1 ; then
        envsubst "$substitutions" <$1 | ldapmodify
    else
        envsubst "$substitutions" <$1 | ldapadd
    fi
}

bootstrap_database() {
    debconf-set-selections <<EOF
slapd slapd/internal/generated_adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/internal/adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/dump_database_destdir string /var/backups/slapd-VERSION
slapd slapd/backend string ${LDAP_BACKEND^^}
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_ORGANISATION-Unknown}
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/no_configuration boolean false
slapd slapd/dump_database select when needed
EOF
    dpkg-reconfigure -f noninteractive slapd

}

catchall() {
    tail -f /dev/null
}

retry() {
    for i in {0..30} ; do
        $@ && return
        sleep $i
    done
    $@
}

setup_acl() {
    # Allow local users to manage database
    ldapmodify <<EOF
dn: olcDatabase={1}${LDAP_BACKEND},cn=config
changetype: modify
replace: olcAccess
olcAccess: to attrs=userPassword by self write by anonymous auth by * none
olcAccess: to *
  by dn.children="cn=peercred,cn=external,cn=auth" manage
  by self write
  by users read
  by anonymous auth
  by * none
EOF
}

setup_tls() {
    TLS_CERT=/var/lib/ldap/cert.pem
    TLS_KEY=${TLS_CERT}
    TLS_CACERT=${TLS_CERT}
    # Beware: debian ships openldap with libgnutls. Use gnutls ciphers here.
    TLS_CIPHERS=NORMAL:!NULL

    openssl req -new -days 365 -nodes -x509 \
            -subj "/C=FR/ST=None/L=None/CN=$LDAP_DOMAIN" \
            -out $TLS_CERT -keyout $TLS_KEY
    test -f $TLS_CERT
    test -f $TLS_KEY
    test -f ${TLS_CACERT}
    chown openldap:openldap ${TLS_CERT} ${TLS_CACERT} ${TLS_KEY}

    ldapmodify << EOF
dn: cn=config
changetype: modify
replace: olcTLSCipherSuite
olcTLSCipherSuite: ${TLS_CIPHERS}
-
add: olcTLSCACertificateFile
olcTLSCACertificateFile: $TLS_CACERT
-
add: olcTLSCertificateFile
olcTLSCertificateFile: $TLS_CERT
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: $TLS_KEY
-
add: olcTLSVerifyClient
olcTLSVerifyClient: never
EOF
}


if [ -n "${DEBUG-}" ] ; then
    trap catchall INT TERM EXIT
else
    EXEC=1
fi

: ${LDAP_LOGLEVEL:=256}

# Check if database #1 exists
if ! slapcat -n 1 -a cn=never_found 2>/dev/null; then
    : ${LDAP_ADMIN_PASSWORD:=admin}
    export LDAP_BACKEND=${LDAP_BACKEND-mdb}
    export LDAP_DOMAIN=${LDAP_DOMAIN-$(hostname --fqdn)}

    bootstrap_database

    base_line=$(slapcat -n1 | grep --max-count=1 ^dn)
    export LDAPBASE=${base_line#dn: }
    export LDAPSASL_MECH=EXTERNAL
    export LDAPURI=ldapi:///

    # Now start a local slapd instance bound to unix socket only. This allow to
    # use ldapadd and ldapmodify instead of slapadd. That may change once
    # OpenLDAP 2.5 comes with slapmodify.

    slapd -h "${LDAPURI}" -u openldap -g openldap -d ${LDAP_LOGLEVEL} &
    retry test -S /run/slapd/ldapi
    # Check the connexion
    retry ldapwhoami -d ${LDAP_LOGLEVEL}

    setup_acl
    setup_tls

    for f in $(find /docker-entrypoint-init.d/ -type f | sort); do
        case $f in
            *.ldif)    addormodify $f ;;
            *.sh)      . $f ;;
            *)         : ignoring $f ;;
        esac
    done

    pid=$(cat /run/slapd/slapd.pid)
    kill -TERM $pid
    retry test '!' -d /proc/$pid/
fi

ulimit -n 1024

${EXEC+exec} \
    /usr/sbin/slapd \
    -h "ldap://0.0.0.0 ldaps://0.0.0.0" \
    -u openldap -g openldap \
    -d ${LDAP_LOGLEVEL} \
    $@
