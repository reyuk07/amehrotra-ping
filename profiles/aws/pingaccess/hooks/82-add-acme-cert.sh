#!/usr/bin/env sh

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"


set -e
"${VERBOSE}" && set -x

# Only add cert to PA admin if K8S_ACME_CERT_SECRET_NAME is set.
if test -z "${K8S_ACME_CERT_SECRET_NAME}"; then
    echo "add-acme-cert: K8S_ACME_CERT_SECRET_NAME is not set skipping"
    exit 0
fi

# FIXME: this needs to not just check if the ACME cert already exists but also whether the tls.crt has changed.

# Check if alias for the cert already exists.
echo "add-acme-cert: checking if certificate with alias '${K8S_ACME_CERT_SECRET_NAME}' already exists"
OUT=$(make_api_request https://localhost:9000/pa-admin-api/v3/certificates?alias=$K8S_ACME_CERT_SECRET_NAME)
ALIAS_NAME=$(echo ${OUT} | jq .items[].id)

# Skip if cert with alias already exists.
if ! test -z "$ALIAS_NAME"; then 
    echo "add-acme-cert: alias already exists '${K8S_ACME_CERT_SECRET_NAME}'"
    exit 0
fi

# Get base64 encoded acme cert from k8s secret.
ACME_CERT=$(kubectl get secret ${K8S_ACME_CERT_SECRET_NAME} -o json | jq -r '.data | .["tls.crt"]')

# Exit with error if unable to retrieve cert.
if test -z "${ACME_CERT}"; then
    echo "add-acme-cert: no certificate found with secret object name ${K8S_ACME_CERT_SECRET_NAME}"
    exit 1
fi

# Get base64 encoded acme cert from k8s secret.
ACME_CERT=$(kubectl get secret acme-tls-cert -o json | jq -r '.data | .["tls.crt"]')

# Exit with error if unable to retrieve cert.
if test -z "${ACME_CERT}"; then
    echo "add-acme-cert: no certificate found with secret object name ${K8S_ACME_CERT_SECRET_NAME}"
    exit 1
fi

# Create temp dir to extract all the certificate in certificate chain
TMP_DIR="$(mktemp -d)"

# Decode and write all the certificate to a file in numerical order
# The SSL certificate chain order consists of root certificates and intermediate certificates
OUT=$(echo ${ACME_CERT} | base64 -d | awk -v tmp="${TMP_DIR}" 'BEGIN {c=0;} /BEGIN CERT/{c++} { print > tmp "/" c ".pem"}')

# Get the certificate file name with highest numerical (intermediate certificate) and encode it
INTERMEDIATE_CERT=$(ls -d ${TMP_DIR}/* | tail -1 | xargs cat | base64)

# Exit with error if unable to retrieve certificate from temp path.
if test -z "${INTERMEDIATE_CERT}"; then
    ls -l "${TMP_DIR}/*"
    echo "add-acme-cert: unable to locate any cert file in temp dir path"
    exit 1
fi

# Added cert to PA admin.
ADD_ACME_CERT_OUT=$(make_api_request -X POST -d "{
        \"alias\": \"${K8S_ACME_CERT_SECRET_NAME}\",
        \"fileData\": \"${INTERMEDIATE_CERT}\"
    }" https://localhost:9000/pa-admin-api/v3/certificates)

# Get cert status from response body.
ACME_CERT_STATUS=$(echo ${ADD_ACME_CERT_OUT} | jq -r '.status')

# Exit 1: if ACME_CERT_STATUS is not set or not equal to string 'Valid'.
if test -z "${ACME_CERT_STATUS}" || test "${ACME_CERT_STATUS}" != 'Valid'; then
  echo "add-acme-cert: failed to get correct cert status: ${ACME_CERT_STATUS}"
  exit 1
fi 

echo "add-acme-cert: successfully added acme cert to PA admin with alias ${K8S_ACME_CERT_SECRET_NAME}"

# Cleanup 
rm -rf ${TMP_DIR}

exit 0