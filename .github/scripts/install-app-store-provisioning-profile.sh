#!/usr/bin/env bash
set -euo pipefail

PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

die() {
  printf 'install-app-store-provisioning-profile: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'install-app-store-provisioning-profile: %s\n' "$*" >&2
}

TEAM_ID="${IOS_APPSTORE_TEAM_ID:-7WLXT3NR37}"
BUNDLE_IDENTIFIER="${IOS_APPSTORE_BUNDLE_IDENTIFIER:-com.cmux.app}"
EXPECTED_APP_ID="${TEAM_ID}.${BUNDLE_IDENTIFIER}"
KEYCHAIN_NAME="${IOS_APPSTORE_KEYCHAIN_NAME:-ios-app-store.keychain}"
TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
TMP_PROFILE="$TMP_ROOT/cmux-appstore.mobileprovision"
TMP_PLIST="$TMP_ROOT/cmux-appstore-profile.plist"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
RESOLVED_PROFILE_NAME=""
RESOLVED_PROFILE_UUID=""

validate_profile() {
  local profile_path="$1"
  local plist_path="$2"
  local label="$3"
  local strict="$4"

  if ! security cms -D -i "$profile_path" > "$plist_path"; then
    if [ "$strict" = "true" ]; then
      die "$label is not a readable provisioning profile"
    fi
    note "$label is not a readable provisioning profile; ignoring"
    return 1
  fi

  local app_id
  app_id="$("$PLISTBUDDY" -c "Print :Entitlements:application-identifier" "$plist_path" 2>/dev/null || true)"
  if [ "$app_id" != "$EXPECTED_APP_ID" ]; then
    if [ "$strict" = "true" ]; then
      die "$label targets unexpected app ID: ${app_id:-<absent>} (expected $EXPECTED_APP_ID)"
    fi
    note "$label targets ${app_id:-<absent>}, expected $EXPECTED_APP_ID; ignoring"
    return 1
  fi

  local aps_environment
  aps_environment="$("$PLISTBUDDY" -c "Print :Entitlements:aps-environment" "$plist_path" 2>/dev/null || true)"
  if [ "$aps_environment" != "production" ]; then
    if [ "$strict" = "true" ]; then
      die "$label aps-environment is '${aps_environment:-<absent>}', expected 'production'"
    fi
    note "$label aps-environment is '${aps_environment:-<absent>}', expected 'production'; ignoring"
    return 1
  fi

  local apple_sign_in
  apple_sign_in="$("$PLISTBUDDY" -c "Print :Entitlements:com.apple.developer.applesignin:0" "$plist_path" 2>/dev/null || true)"
  if [ "$apple_sign_in" != "Default" ]; then
    if [ "$strict" = "true" ]; then
      die "$label com.apple.developer.applesignin is '${apple_sign_in:-<absent>}', expected 'Default'"
    fi
    note "$label com.apple.developer.applesignin is '${apple_sign_in:-<absent>}', expected 'Default'; ignoring"
    return 1
  fi

  RESOLVED_PROFILE_NAME="$("$PLISTBUDDY" -c "Print :Name" "$plist_path")"
  RESOLVED_PROFILE_UUID="$("$PLISTBUDDY" -c "Print :UUID" "$plist_path")"
  return 0
}

install_profile() {
  mkdir -p "$PROFILE_DIR"
  cp "$TMP_PROFILE" "$PROFILE_DIR/$RESOLVED_PROFILE_UUID.mobileprovision"
  echo "IOS_APPSTORE_PROVISIONING_PROFILE_NAME=$RESOLVED_PROFILE_NAME" >> "$GITHUB_ENV"
  note "installed App Store profile '$RESOLVED_PROFILE_NAME'"
}

try_secret_profile() {
  local label="$1"
  local value="$2"
  local strict="$3"

  if [ -z "$value" ]; then
    return 1
  fi

  printf '%s' "$value" | base64 --decode > "$TMP_PROFILE"
  if validate_profile "$TMP_PROFILE" "$TMP_PLIST" "$label" "$strict"; then
    install_profile
    return 0
  fi
  return 1
}

json_id_by_bundle_identifier() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, identifier = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    body = json.load(handle)
data = body.get("data", body) if isinstance(body, dict) else body
for item in data if isinstance(data, list) else []:
    if item.get("attributes", {}).get("identifier") == identifier:
        print(item.get("id", ""))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

json_certificate_id_by_serial() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

def norm(value):
    return "".join(ch for ch in str(value).upper() if ch.isalnum())

path, serial = sys.argv[1], norm(sys.argv[2])
with open(path, "r", encoding="utf-8") as handle:
    body = json.load(handle)
data = body.get("data", body) if isinstance(body, dict) else body
for item in data if isinstance(data, list) else []:
    if norm(item.get("attributes", {}).get("serialNumber", "")) == serial:
        print(item.get("id", ""))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

print_certificate_summary() {
  python3 - "$1" <<'PY' >&2
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    body = json.load(handle)
data = body.get("data", body) if isinstance(body, dict) else body
items = data if isinstance(data, list) else []
if not items:
    print("install-app-store-provisioning-profile: no distribution certificate candidates returned")
    raise SystemExit(0)
print("install-app-store-provisioning-profile: distribution certificate candidates:")
for item in items:
    attrs = item.get("attributes", {})
    serial = str(attrs.get("serialNumber", ""))
    suffix = serial[-8:] if serial else "<absent>"
    cert_type = attrs.get("certificateType", "<unknown>")
    display = attrs.get("displayName") or attrs.get("name") or "<unnamed>"
    print(f"install-app-store-provisioning-profile: - {cert_type} {display} serial_suffix={suffix}")
PY
}

json_profile_id_by_name() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    body = json.load(handle)
data = body.get("data", body) if isinstance(body, dict) else body
for item in data if isinstance(data, list) else []:
    if item.get("attributes", {}).get("name") == name:
        print(item.get("id", ""))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

json_single_id() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    body = json.load(handle)
data = body.get("data", body) if isinstance(body, dict) else None
if isinstance(data, dict):
    print(data.get("id", ""))
elif isinstance(data, list) and data:
    print(data[0].get("id", ""))
else:
    raise SystemExit(1)
PY
}

download_profile_from_asc() {
  command -v asc >/dev/null || die "release upload CLI is required"
  command -v python3 >/dev/null || die "python3 is required"
  command -v openssl >/dev/null || die "openssl is required"

  export ASC_KEY_ID="${ASC_KEY_ID:-${ASC_API_KEY_ID:-}}"
  export ASC_ISSUER_ID="${ASC_ISSUER_ID:-${ASC_API_ISSUER_ID:-}}"
  export ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-${ASC_API_KEY_PATH:-}}"
  if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_PRIVATE_KEY_PATH:-}" ]; then
    die "upload credentials are required to fetch a profile"
  fi

  if [ -z "${IOS_DISTRIBUTION_IDENTITY:-}" ]; then
    die "distribution signing identity is required to resolve the matching certificate"
  fi

  local cert_pem cert_serial
  cert_pem="$TMP_ROOT/ios-distribution-cert.pem"
  security find-certificate -c "$IOS_DISTRIBUTION_IDENTITY" -p "$KEYCHAIN_NAME" > "$cert_pem" ||
    die "could not read imported distribution certificate from $KEYCHAIN_NAME"
  cert_serial="$(openssl x509 -in "$cert_pem" -noout -serial | sed 's/^serial=//' | tr '[:lower:]' '[:upper:]')"
  cert_serial="$(printf '%s' "$cert_serial" | tr -cd '[:alnum:]')"
  [ -n "$cert_serial" ] || die "could not resolve imported distribution certificate serial"

  local bundles_json certs_json profiles_json created_json bundle_id certificate_id profile_id profile_name profile_suffix
  bundles_json="$TMP_ROOT/asc-bundle-ids.json"
  certs_json="$TMP_ROOT/asc-certificates.json"
  profiles_json="$TMP_ROOT/asc-profiles.json"
  created_json="$TMP_ROOT/asc-created-profile.json"

  asc bundle-ids list --paginate --output json > "$bundles_json"
  bundle_id="$(json_id_by_bundle_identifier "$bundles_json" "$BUNDLE_IDENTIFIER")" ||
    die "configured bundle id not found for $BUNDLE_IDENTIFIER"

  asc certificates list --certificate-type IOS_DISTRIBUTION,DISTRIBUTION --paginate --output json > "$certs_json"
  certificate_id="$(json_certificate_id_by_serial "$certs_json" "$cert_serial" || true)"
  if [ -z "$certificate_id" ]; then
    print_certificate_summary "$certs_json"
    die "matching distribution certificate not found for imported certificate serial suffix ${cert_serial: -8}"
  fi

  profile_suffix="${cert_serial: -8}"
  profile_name="cmux App Store CI $profile_suffix"
  asc profiles list --profile-type IOS_APP_STORE --paginate --output json > "$profiles_json"
  profile_id="$(json_profile_id_by_name "$profiles_json" "$profile_name" || true)"
  if [ -z "$profile_id" ]; then
    note "creating App Store profile '$profile_name'"
    asc profiles create \
      --name "$profile_name" \
      --profile-type IOS_APP_STORE \
      --bundle "$bundle_id" \
      --certificate "$certificate_id" \
      --output json > "$created_json"
    profile_id="$(json_single_id "$created_json")" ||
      die "could not read created profile id"
  else
    note "reusing App Store profile '$profile_name'"
  fi

  rm -f "$TMP_PROFILE"
  asc profiles download --id "$profile_id" --output "$TMP_PROFILE" >/dev/null
  validate_profile "$TMP_PROFILE" "$TMP_PLIST" "downloaded profile '$profile_name'" "true"
  install_profile
}

if try_secret_profile "primary profile secret" "${IOS_APPSTORE_PROVISIONING_PROFILE_BASE64:-}" "false"; then
  exit 0
fi

for candidate in \
  "legacy production profile secret:${IOS_PROD_PROVISIONING_PROFILE_BASE64:-}" \
  "beta profile secret:${IOS_BETA_PROVISIONING_PROFILE_BASE64:-}" \
  "release profile secret:${APPLE_RELEASE_PROVISIONING_PROFILE_BASE64:-}" \
  "nightly profile secret:${APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64:-}"
do
  label="${candidate%%:*}"
  value="${candidate#*:}"
  if try_secret_profile "$label" "$value" "false"; then
    exit 0
  fi
done

download_profile_from_asc
