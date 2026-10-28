#!/usr/bin/env bash
# TestFlight build of cmux-next-ios for App Store Connect app "cmux INTERNAL"
# (bundle dev.cmux.app.internal, ASC app id 6791408425): archive -> export an
# App Store IPA -> verify -> validate with Apple. Nothing is uploaded unless
# --upload is passed. Never targets cmux (com.cmux.app), BETA or DEMO.
#
# usage: cmux-next-ios/scripts/testflight-build.sh [--ref <git ref>] [--marketing-version X.Y.Z]
#          [--build-number N] [--internal-only] [--allow-backend-down]
#          [--allow-package-drift] [--unsigned] [--skip-validate] [--upload]
#          [--no-asc] [--from-archive <CmuxMobileApp.xcarchive>] [--config TestFlight|TestFlightStaging]
#          [--what-to-test <text>]
#
#   --ref                 commit to build (default HEAD); the source is `git archive` of it
#   --marketing-version   CFBundleShortVersionString (default: project.yml MARKETING_VERSION);
#                         must be >= every version already uploaded to cmux INTERNAL
#   --build-number        CFBundleVersion (default: 14-digit UTC timestamp, like the
#                         ios/ INTERNAL lane); must be above the latest INTERNAL build
#   --internal-only       testFlightInternalTestingOnly: the build can never go to
#                         external groups (e.g. "cmux family")
#   --allow-backend-down  archive even if the production Worker's /v1/health is not
#                         live with only the production Stack project (never with --upload)
#   --allow-package-drift build even if CmuxTabsKit/CmuxConversation differ from upstream
#   --unsigned            no distribution identity needed: archive unsigned and run the
#                         binary checks only (no export, no validation)
#   --skip-validate       skip `altool --validate-app`
#   --upload              upload the validated IPA to cmux INTERNAL (off by default)
#   --no-asc              build host without App Store Connect access: skip every ASC
#                         call; needs --unsigned, --marketing-version and --build-number
#   --config              TestFlight (default: production) or TestFlightStaging (the same app
#                         record and signing, with the development Stack project, the dev
#                         cmux-mobile-api Worker and cloud-api-staging; project.yml)
#   --what-to-test        with --upload: the build's en-US "What to Test" note
#   --from-archive        sign, check, validate (and with --upload, upload) an unsigned
#                         CmuxMobileApp.xcarchive made on a build host with --unsigned --no-asc;
#                         --ref must name the commit it was built from. Version and build
#                         number come from the archive and are checked against ASC.
#
# Environment:
#   CMUX_MOBILE_PROD_API_BASE   production Worker URL (default: project.yml)
#   CMUX_MOBILE_PROFILE_PATH    use this .mobileprovision instead of downloading CMUX_MOBILE_PROFILE_NAME (CI)
#   CMUX_MOBILE_PROFILE_NAME    App Store profile for dev.cmux.app.internal (default
#                       "cmux Internal Distribution")
#   CMUX_MOBILE_CONTENT_EXTENSION_PROFILE_PATH, CMUX_MOBILE_CONTENT_EXTENSION_PROFILE_NAME
#                       the same for the notification content extension
#                       (dev.cmux.app.internal.notification-content; default
#                       "cmux Internal Distribution Notification Content")
#   CMUX_MOBILE_SERVICE_EXTENSION_PROFILE_PATH, CMUX_MOBILE_SERVICE_EXTENSION_PROFILE_NAME
#                       the same for the notification service extension
#                       (dev.cmux.app.internal.notification-service; default
#                       "cmux Internal Distribution Notification Service")
#   CMUX_MOBILE_SIGN_IDENTITY   SHA-1 of the distribution identity (default: the first one in
#                       the keychain that the profile authorizes)
#   CMUX_MOBILE_BUILDS_ROOT     output root (default ~/cmux-mobile-builds)
#   CMUX_MOBILE_XCFRAMEWORK     use this CmuxMobileLinkFFI.xcframework instead of the cache or a build
#
#   CMUX_MOBILE_CI_ASC=1        CI only (.github/workflows/ios-internal-nightly.yml): App Store
#                       Connect credentials come from ASC_KEY_ID, ASC_ISSUER_ID and
#                       ASC_PRIVATE_KEY_PATH (the release environment's key) instead
#                       of the local asc profile; the app record is still checked.
#
# Credentials: locally, App Store Connect calls use only the shared profile
# "cmux-shared Team Key" (key RUML2V4CW7) via `asc --strict-auth`. altool needs
# the key as a file: it is copied from the asc keychain item into a private
# temp directory for the one call and removed on exit; it is never printed.
#
# Output: ~/cmux-mobile-builds/<UTC date>-<shortsha>-testflight/
#   CmuxMobileApp.xcarchive, CmuxMobileApp.ipa, ExportOptions.plist, MANIFEST.md, logs/
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# --- Fixed identity (never derived from the environment) ------------------
app_id=6791408425
app_name="cmux INTERNAL"
bundle_id=dev.cmux.app.internal
team=7WLXT3NR37
asc_profile="cmux-shared Team Key"
asc_key_id=RUML2V4CW7
asc_issuer=94d76068-119d-45cd-8700-86eb7a1a6235
profile_name=${CMUX_MOBILE_PROFILE_NAME:-cmux Internal Distribution}
# The notification content extension (verify/rich-push.md "Extensions and signing").
ext_bundle_id=$bundle_id.notification-content
ext_profile_name=${CMUX_MOBILE_CONTENT_EXTENSION_PROFILE_NAME:-cmux Internal Distribution Notification Content}
svc_bundle_id=$bundle_id.notification-service
svc_profile_name=${CMUX_MOBILE_SERVICE_EXTENSION_PROFILE_NAME:-cmux Internal Distribution Notification Service}
prod_stack_project=9790718f-14cd-4f7e-824d-eaf527a82b82
dev_stack_project=454ecd03-1db2-4050-845e-4ce5b0cd9895
config=TestFlight what_to_test=""

ref=HEAD marketing="" build_number="" internal_only=false allow_backend_down=0
allow_drift=0 unsigned=0 skip_validate=0 upload=0 no_asc=0 from_archive=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref=$2; shift 2 ;;
    --marketing-version) marketing=$2; shift 2 ;;
    --build-number) build_number=$2; shift 2 ;;
    --internal-only) internal_only=true; shift ;;
    --allow-backend-down) allow_backend_down=1; shift ;;
    --allow-package-drift) allow_drift=1; shift ;;
    --unsigned) unsigned=1; shift ;;
    --skip-validate) skip_validate=1; shift ;;
    --upload) upload=1; shift ;;
    --no-asc) no_asc=1; shift ;;
    --config) config=$2; shift 2 ;;
    --what-to-test) what_to_test=$2; shift 2 ;;
    --from-archive) from_archive=$2; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ $upload == 1 && ( $allow_backend_down == 1 || $unsigned == 1 || $skip_validate == 1 || $allow_drift == 1 ) ]]; then
  echo "error: --upload cannot be combined with --allow-backend-down, --unsigned, --skip-validate or --allow-package-drift" >&2
  exit 2
fi
case "$config" in
  TestFlight)        stack_project=$prod_stack_project cloud_api_base=https://cloud-api.cmux.dev
                     api_key=CMUX_MOBILE_PROD_API_BASE stack_env="" binary_mode=--shipping ;;
  TestFlightStaging) stack_project=$dev_stack_project cloud_api_base=https://cloud-api-staging.cmux.dev
                     api_key=CMUX_MOBILE_STAGING_API_BASE stack_env=development binary_mode=--staging-shipping ;;
  *) echo "error: --config must be TestFlight or TestFlightStaging" >&2; exit 2 ;;
esac
if [[ $no_asc == 1 && ( $unsigned == 0 || -z "$marketing" || -z "$build_number" || -n "$from_archive" ) ]]; then
  echo "error: --no-asc needs --unsigned, --marketing-version and --build-number, and no --from-archive" >&2
  exit 2
fi
if [[ -n "$from_archive" ]]; then
  [[ $unsigned == 0 ]] || { echo "error: --from-archive signs; it cannot be --unsigned" >&2; exit 2; }
  [[ -d "$from_archive/Products/Applications/CmuxMobileApp.app" ]] || { echo "error: $from_archive has no Products/Applications/CmuxMobileApp.app" >&2; exit 2; }
  [[ -z "$marketing$build_number" ]] || { echo "error: --from-archive takes the version and build number from the archive" >&2; exit 2; }
  from_archive=$(cd "$from_archive" && pwd)
  marketing=$(plutil -extract CFBundleShortVersionString raw "$from_archive/Products/Applications/CmuxMobileApp.app/Info.plist")
  build_number=$(plutil -extract CFBundleVersion raw "$from_archive/Products/Applications/CmuxMobileApp.app/Info.plist")
fi

ci_asc=${CMUX_MOBILE_CI_ASC:-0}
if [[ $ci_asc == 1 ]]; then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_PRIVATE_KEY_PATH:-}" ]] \
    || { echo "error: CMUX_MOBILE_CI_ASC=1 needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH" >&2; exit 2; }
  asc_key_id=$ASC_KEY_ID asc_issuer=$ASC_ISSUER_ID
  asc_cmd=(asc)
else
  asc_cmd=(asc --profile "$asc_profile" --strict-auth)
fi
# The asc command line; set-test-notes.sh runs it in a child process, where a function is not visible.
asc_() { "${asc_cmd[@]}" "$@"; }
log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
json() { python3 -I -c "$1" 2>/dev/null; }  # reads one JSON document on stdin (asc may append warnings)
notes=()

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$script_dir" rev-parse --show-toplevel)
sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}")
short=${sha:0:10}
root=${CMUX_MOBILE_BUILDS_ROOT:-$HOME/cmux-mobile-builds}
name="$(date -u +%Y%m%d)-$short-testflight"
out="$root/$name"
work="$root/.work/$name"
cache="$root/.cache"
private=$(mktemp -d); chmod 700 "$private"
trap 'rm -rf "$private"' EXIT

# --- App Store Connect: credentials and the exact app record ----------------
max_marketing="not checked (--no-asc)" max_build="not checked (--no-asc)"
if [[ $no_asc == 0 ]]; then
log "App Store Connect: profile, app record"
[[ $ci_asc == 1 ]] || asc_ auth status --validate --output json | json '
import json,sys
d=json.JSONDecoder().raw_decode(sys.stdin.read())[0]
ok=d.get("profile")=="cmux-shared Team Key" and any(
    c["name"]=="cmux-shared Team Key" and c["keyId"]=="RUML2V4CW7" and c.get("validation")=="works"
    for c in d["credentials"])
sys.exit(0 if ok else 1)' || die "asc profile \"$asc_profile\" is missing, invalid, or not key $asc_key_id"
record=$(asc_ apps view --id "$app_id" --output json | json '
import json,sys
a=json.JSONDecoder().raw_decode(sys.stdin.read())[0]["data"]["attributes"]
print(a["name"]+"|"+a["bundleId"])')
[[ "$record" == "$app_name|$bundle_id" ]] || die "app $app_id is \"$record\", expected \"$app_name|$bundle_id\""
echo "app $app_id = $app_name ($bundle_id), key $asc_key_id"

# --- Versions above everything already in cmux INTERNAL --------------------
log "versions"
max_marketing=$(asc_ testflight pre-release list --app "$app_id" --paginate --output json | json '
import json,sys
d=json.JSONDecoder().raw_decode(sys.stdin.read())[0]
v=[tuple(map(int,x["attributes"]["version"].split("."))) for x in d["data"]]
print(".".join(map(str,max(v))) if v else "0")')
max_build=$(asc_ builds list --app "$app_id" --paginate --output json | json '
import json,sys
d=json.JSONDecoder().raw_decode(sys.stdin.read())[0]["data"]
v=[int(x["attributes"]["version"]) for x in d if x["attributes"]["version"].isdigit()]
print(max(v) if v else 0)')
[[ -n "$marketing" ]] || marketing=$(git -C "$repo" show "$sha:cmux-next-ios/project.yml" | awk '/^    MARKETING_VERSION:/{print $2; exit}')
[[ "$marketing" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "marketing version '$marketing' is not X.Y.Z"
python3 -I -c 'import sys; a,b=(tuple(map(int,x.split("."))) for x in sys.argv[1:]); sys.exit(0 if a>=b else 1)' "$marketing" "$max_marketing" \
  || die "marketing version $marketing is below $max_marketing, the highest in $app_name; TestFlight would never offer it"
[[ -n "$build_number" ]] || build_number=$(date -u +%Y%m%d%H%M%S)
[[ "$build_number" =~ ^[0-9]+$ ]] || die "build number '$build_number' must be digits (the INTERNAL lane uses UTC timestamps)"
python3 -I -c 'import sys; sys.exit(0 if int(sys.argv[1])>int(sys.argv[2]) else 1)' "$build_number" "$max_build" \
  || die "build number $build_number is not above $max_build, the latest $app_name build"
echo "version $marketing ($build_number); $app_name has up to $max_marketing ($max_build)"
else
  log "App Store Connect: skipped (--no-asc)"
  [[ "$marketing" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "marketing version '$marketing' is not X.Y.Z"
  [[ "$build_number" =~ ^[0-9]+$ ]] || die "build number '$build_number' must be digits"
  notes+=("Built with --no-asc: version and build number were not checked against App Store Connect here; --from-archive checks them before upload.")
fi

# --- Backend (production, or staging for TestFlightStaging) ----------------
api_base=$(git -C "$repo" show "$sha:cmux-next-ios/project.yml" | awk -v k="    $api_key:" 'index($0,k)==1{print $2; exit}' | sed 's#\$()##')
[[ $config != TestFlight || -z "${CMUX_MOBILE_PROD_API_BASE:-}" ]] || api_base=$CMUX_MOBILE_PROD_API_BASE
[[ -n "$api_base" ]] || die "$sha has no $api_key in project.yml"
log "$config Worker $api_base"
health=$(curl -fsS -m 15 "$api_base/v1/health" 2>/dev/null || true)
if echo "$health" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
p=d.get("stackProjects") or []
ok=p==[sys.argv[1]] if sys.argv[2]=="TestFlight" else sys.argv[1] in p
sys.exit(0 if d.get("ok") and ok else 1)' "$stack_project" "$config" 2>/dev/null; then
  echo "live: $health"
elif [[ $allow_backend_down == 1 ]]; then
  echo "WARNING: $api_base/v1/health is not a live production Worker (${health:-no response}); continuing (--allow-backend-down)" >&2
  notes+=("The production Worker \`$api_base\` was not live at build time (\`/v1/health\`: ${health:-no response}). Do not distribute this build.")
else
  die "$api_base/v1/health is not a live $config Worker for Stack project $stack_project (got: ${health:-no response})."
fi
cloud_health=$(curl -fsS -m 15 "$cloud_api_base/v1/health" 2>/dev/null || true)
if [[ "$cloud_health" == *'"ok":true'* ]]; then
  echo "Cloud service $cloud_api_base live: $cloud_health"
else
  [[ $allow_backend_down == 1 ]] || die "Cloud service $cloud_api_base/v1/health is not live (got: ${cloud_health:-no response})"
fi

# --- Shared packages must match upstream -----------------------------------
log "shared packages vs upstream"
if ! "$script_dir/check-tabskit-sync.sh" --ref "$sha"; then
  [[ $allow_drift == 1 ]] || die "shared iOS packages differ from upstream; sync them or pass --allow-package-drift (never for an upload)"
  notes+=("Shared packages differ from upstream (check-tabskit-sync.sh).")
fi

# --- Signing material -------------------------------------------------------
profile_path="" profile_uuid="" identity="" ext_profile_path="" ext_profile_uuid="" svc_profile_path="" svc_profile_uuid=""
if [[ $unsigned == 0 ]]; then
  log "signing: profile \"$profile_name\", distribution identity"
  # fetch_profile <bundle id> <profile name> <CI file or ""> <out base>: the
  # ACTIVE App Store profile, checked and installed; prints its UUID.
  fetch_profile() {
    local bid=$1 name=$2 file=$3 dest=$4 pid uuid expiry d
    if [[ -n "$file" ]]; then
      # CI: the release environment's copy of the profile (the one that lists
      # CI's distribution certificate), not App Store Connect's current version.
      [[ -f "$file" ]] || die "$file is not a file"
      cp "$file" "$dest.mobileprovision"
      pid="file"
    else
      pid=$(asc_ bundle-ids list --paginate --output json | BID="$bid" json '
import json,os,sys
d=json.JSONDecoder().raw_decode(sys.stdin.read())[0]
print(next(b["id"] for b in d["data"] if b["attributes"]["identifier"]==os.environ["BID"]))' \
        | { read -r id; asc_ bundle-ids profiles list --id "$id" --output json; } | CMUX_MOBILE_PROFILE_NAME="$name" json '
import json,os,sys
d=json.JSONDecoder().raw_decode(sys.stdin.read())[0]
p=[p for p in d["data"] if p["attributes"]["name"]==os.environ["CMUX_MOBILE_PROFILE_NAME"]
   and p["attributes"]["profileType"]=="IOS_APP_STORE" and p["attributes"]["profileState"]=="ACTIVE"]
print(p[0]["id"] if p else "")')
      [[ -n "$pid" ]] || die "no ACTIVE IOS_APP_STORE profile \"$name\" for $bid"
      asc_ profiles download --id "$pid" --output "$dest.mobileprovision" >/dev/null
    fi
    security cms -D -i "$dest.mobileprovision" > "$dest.plist"
    uuid=$(plutil -extract UUID raw "$dest.plist")
    expiry=$(plutil -extract ExpirationDate raw "$dest.plist")
    [[ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" < "$expiry" ]] || die "profile $uuid expired $expiry"
    [[ "$(plutil -extract Entitlements.application-identifier raw "$dest.plist")" == "$team.$bid" ]] \
      || die "profile $pid is not for $team.$bid"
    # Xcode 16+ reads profiles from UserData; older tools from MobileDevice.
    for d in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
      mkdir -p "$d"; cp "$dest.mobileprovision" "$d/$uuid.mobileprovision"
    done
    echo "$uuid"
  }
  profile_uuid=$(fetch_profile "$bundle_id" "$profile_name" "${CMUX_MOBILE_PROFILE_PATH:-}" "$private/profile")
  ext_profile_uuid=$(fetch_profile "$ext_bundle_id" "$ext_profile_name" "${CMUX_MOBILE_CONTENT_EXTENSION_PROFILE_PATH:-}" "$private/ext-profile")
  profile_path="$private/profile.mobileprovision"
  ext_profile_path="$private/ext-profile.mobileprovision"
  svc_profile_uuid=$(fetch_profile "$svc_bundle_id" "$svc_profile_name" "${CMUX_MOBILE_SERVICE_EXTENSION_PROFILE_PATH:-}" "$private/svc-profile")
  svc_profile_path="$private/svc-profile.mobileprovision"
  # One identity signs both: the extension's profile must allow it too.
  ext_authorized=$(python3 -I -c '
import plistlib,hashlib,sys
p=plistlib.load(open(sys.argv[1],"rb"))
print("\n".join(hashlib.sha1(c).hexdigest().upper() for c in p["DeveloperCertificates"]))' "$private/ext-profile.plist")
  svc_authorized=$(python3 -I -c '
import plistlib,hashlib,sys
p=plistlib.load(open(sys.argv[1],"rb"))
print("\n".join(hashlib.sha1(c).hexdigest().upper() for c in p["DeveloperCertificates"]))' "$private/svc-profile.plist")
  keychain_ids=$(security find-identity -v -p codesigning | awk '/[0-9A-F]{40}/{print $2}')
  authorized=$(python3 -I -c '
import plistlib,hashlib,sys
p=plistlib.load(open(sys.argv[1],"rb"))
print("\n".join(hashlib.sha1(c).hexdigest().upper() for c in p["DeveloperCertificates"]))' "$private/profile.plist")
  if [[ -n "${CMUX_MOBILE_SIGN_IDENTITY:-}" ]]; then
    identity=$CMUX_MOBILE_SIGN_IDENTITY
  else
    identity=$(grep -Fx -f <(echo "$authorized") <<<"$keychain_ids" | head -1 || true)
  fi
  if [[ -z "$identity" ]] || ! grep -qx "$identity" <<<"$keychain_ids" || ! grep -qx "$identity" <<<"$authorized"; then
    die "no distribution identity in this keychain that \"$profile_name\" authorizes. The profile allows these certificate SHA-1s:
$(sed 's/^/  /' <<<"$authorized")
Import one of their .p12 files into the login keychain (see verify/testflight-readiness.md), or rerun with --unsigned for an unsigned archive."
  fi
  grep -qx "$identity" <<<"$ext_authorized" || die "\"$ext_profile_name\" does not authorize identity $identity (the app's); regenerate it with the same certificates as \"$profile_name\""
  grep -qx "$identity" <<<"$svc_authorized" || die "\"$svc_profile_name\" does not authorize identity $identity (the app's); regenerate it with the same certificates as \"$profile_name\""
  echo "profile $profile_uuid, extension profiles $ext_profile_uuid $svc_profile_uuid, identity $identity"
fi

if [[ -n "$from_archive" ]]; then
  built_from=$(plutil -extract CmuxMobileSourceCommit raw "$from_archive/Products/Applications/CmuxMobileApp.app/Info.plist" 2>/dev/null || true)
  [[ "$built_from" == "$sha" ]] || die "$from_archive was built from '${built_from:-unknown}', not $sha (--ref)"
  case "$from_archive/" in
    "$out/"*|"$work/"*) ditto "$from_archive" "$private/CmuxMobileApp.xcarchive"; from_archive="$private/CmuxMobileApp.xcarchive" ;;
  esac
fi
rm -rf "$out" "$work"
mkdir -p "$out/logs" "$work/src" "$cache"
if [[ -n "$from_archive" ]]; then
  log "cmux-next-ios $config: sign the archive $from_archive ($sha) -> $out"
  archive=$from_archive
else
log "cmux-next-ios $config archive $sha -> $out"

# --- Source (the commit only) ----------------------------------------------
paths=(cmux-next-ios Packages vendor/stack-auth-swift-sdk-prerelease AppIcon.icon
       cmux-tui schemas backend/catalog backend/packages plans/cmux-next skills mux samples)
git -C "$repo" archive --format=tar "$sha" "${paths[@]}" | tar -x -C "$work/src"

# --- CmuxMobileLinkFFI.xcframework (gitignored; same cache key as demo-build.sh) ------
key=$(printf '%s\n' "$(git -C "$repo" rev-parse "$sha:cmux-next-ios/rust")" \
  "$(git -C "$repo" rev-parse "$sha:cmux-tui/crates/cmux-wg")" \
  "$(git -C "$repo" rev-parse "$sha:cmux-tui/crates/cmux-transport")" | shasum | cut -c1-16)
xcf_dest="$work/src/cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework"
mkdir -p "$(dirname "$xcf_dest")"
if [[ -n "${CMUX_MOBILE_XCFRAMEWORK:-}" ]]; then
  cp -R "$CMUX_MOBILE_XCFRAMEWORK" "$xcf_dest"
  notes+=("CmuxMobileLinkFFI.xcframework came from CMUX_MOBILE_XCFRAMEWORK, not built from this SHA.")
elif [[ -d "$cache/xcframework/$key/CmuxMobileLinkFFI.xcframework" ]]; then
  echo "xcframework: cache hit $key"
  cp -R "$cache/xcframework/$key/CmuxMobileLinkFFI.xcframework" "$xcf_dest"
else
  log "xcframework: building (key $key)"
  mkdir -p "$cache/cmux-mobile-rust-target"
  ln -s "$cache/cmux-mobile-rust-target" "$work/src/cmux-next-ios/rust/target"
  JOBS=${JOBS:-8} bash "$work/src/cmux-next-ios/rust/scripts/build-xcframework.sh" > "$out/logs/xcframework.log" 2>&1 \
    || { tail -30 "$out/logs/xcframework.log"; exit 1; }
  rm -rf "$cache/xcframework/$key"; mkdir -p "$cache/xcframework/$key"
  cp -R "$xcf_dest" "$cache/xcframework/$key/"
fi

# --- Archive ----------------------------------------------------------------
cd "$work/src/cmux-next-ios"
xcodegen generate -q
grep -q "^  $config: release" project.yml || die "$sha has no $config configuration"
archive="$out/CmuxMobileApp.xcarchive"
args=(-project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration "$config"
      -destination 'generic/platform=iOS' -archivePath "$archive"
      -derivedDataPath "$work/dd" -clonedSourcePackagesDirPath "$cache/spm"
      MARKETING_VERSION="$marketing" CURRENT_PROJECT_VERSION="$build_number"
      CMUX_MOBILE_SOURCE_COMMIT="$sha")
[[ $config != TestFlight ]] || args+=(CMUX_MOBILE_PROD_API_BASE="$api_base")
if [[ $unsigned == 1 ]]; then
  args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=$team)
else
  # Per target (project.yml): a global PROVISIONING_PROFILE_SPECIFIER would
  # give the extension the app's profile.
  args+=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$team CODE_SIGN_IDENTITY="$identity"
         CMUX_MOBILE_APP_PROFILE="$profile_uuid" CMUX_MOBILE_CONTENT_EXTENSION_PROFILE="$ext_profile_uuid"
         CMUX_MOBILE_SERVICE_EXTENSION_PROFILE="$svc_profile_uuid")
fi
log "xcodebuild archive"
xcodebuild archive "${args[@]}" > "$out/logs/archive.log" 2>&1 \
  || { grep -E "error:|ARCHIVE FAILED" "$out/logs/archive.log" | sort -u | head -20; die "archive failed (logs/archive.log)"; }
fi
archived_app="$archive/Products/Applications/CmuxMobileApp.app"
if [[ -z "$from_archive" && -n "${CMUX_MOBILE_SIMULATOR_APP:-}" ]]; then
  # A simulator app of the same commit and configuration, for the fleet
  # simulator check (scripts/verify-remote.sh ios --client-app). Signed ad hoc
  # with the configuration's entitlements (Xcode's simulated entitlements, no
  # team): an unsigned app has no keychain group, so its Keychain writes fail
  # (-34018) and it can neither keep a session nor make pairing keys.
  log "xcodebuild build (iphonesimulator) -> $CMUX_MOBILE_SIMULATOR_APP"
  sim_args=(-project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration "$config"
            -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/dd-sim"
            -clonedSourcePackagesDirPath "$cache/spm"
            MARKETING_VERSION="$marketing" CURRENT_PROJECT_VERSION="$build_number" CMUX_MOBILE_SOURCE_COMMIT="$sha"
            CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
  [[ $config != TestFlight ]] || sim_args+=(CMUX_MOBILE_PROD_API_BASE="$api_base")
  xcodebuild build "${sim_args[@]}" > "$out/logs/simulator.log" 2>&1 \
    || { grep -E "error:" "$out/logs/simulator.log" | sort -u | head -20; die "simulator build failed (logs/simulator.log)"; }
  mkdir -p "$(dirname "$CMUX_MOBILE_SIMULATOR_APP")"
  rm -rf "$CMUX_MOBILE_SIMULATOR_APP"
  ditto "$work/dd-sim/Build/Products/$config-iphonesimulator/CmuxMobileApp.app" "$CMUX_MOBILE_SIMULATOR_APP"
fi

# --- Checks on any app bundle ------------------------------------------------
check_app() {  # <CmuxMobileApp.app>
  local app=$1 info="$1/Info.plist" bad=()
  bash "$script_dir/check-production-binary.sh" "$app" "$bundle_id" "$binary_mode"
  # What App Store Connect rejects only after the upload (ITMS-90626, 90683, ...).
  python3 -I "$repo/scripts/cmux-next/check-app-store-rules.py" --app "$app" || die "$app breaks an App Store review rule"
  [[ "$(plutil -extract CmuxMobileStackEnvironment raw "$info" 2>/dev/null)" == "$stack_env" ]] || bad+=("CmuxMobileStackEnvironment (want '$stack_env')")
  [[ "$(plutil -extract CFBundleShortVersionString raw "$info")" == "$marketing" ]] || bad+=("CFBundleShortVersionString")
  [[ "$(plutil -extract CFBundleVersion raw "$info")" == "$build_number" ]] || bad+=("CFBundleVersion")
  [[ "$(plutil -extract CFBundleDisplayName raw "$info")" == "$app_name" ]] || bad+=("CFBundleDisplayName")
  [[ "$(plutil -extract CmuxMobileAPIBase raw "$info")" == "$api_base" ]] || bad+=("CmuxMobileAPIBase")
  [[ "$(plutil -extract CmuxMobileCloudAPIBase raw "$info" 2>/dev/null)" == "$cloud_api_base" ]] || bad+=("CmuxMobileCloudAPIBase (want $cloud_api_base)")
  [[ "$(plutil -extract CmuxMobileSourceCommit raw "$info" 2>/dev/null)" == "$sha" ]] || bad+=("CmuxMobileSourceCommit (want $sha)")
  [[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$info")" == false ]] || bad+=("ITSAppUsesNonExemptEncryption (project.yml explains false)")
  local k; for k in NSCameraUsageDescription NSPhotoLibraryUsageDescription NSPhotoLibraryAddUsageDescription \
      NSMicrophoneUsageDescription NSLocalNetworkUsageDescription UILaunchScreen; do
    plutil -extract "$k" raw "$info" >/dev/null 2>&1 || plutil -extract "$k" xml1 -o /dev/null "$info" 2>/dev/null || bad+=("$k")
  done
  plutil -extract CFBundleIcons.CFBundlePrimaryIcon xml1 -o /dev/null "$info" 2>/dev/null || bad+=("CFBundleIcons (app icon)")
  [[ -f "$app/Assets.car" ]] || bad+=("Assets.car")
  plutil -lint -s "$app/PrivacyInfo.xcprivacy" 2>/dev/null || bad+=("PrivacyInfo.xcprivacy")
  [[ ${#bad[@]} == 0 ]] || { printf '  - %s\n' "${bad[@]}" >&2; die "$app fails the TestFlight checks"; }
  echo "ok: Info.plist, icon, launch screen, privacy manifest, usage strings"
}

# Entitlements of a signed app must be exactly what TestFlight needs.
check_entitlements() {  # <CmuxMobileApp.app>
  codesign --verify --strict --deep "$1"
  codesign -d --entitlements - --xml "$1" 2>/dev/null > "$private/ent.plist"
  python3 -I - "$private/ent.plist" "$team" "$bundle_id" <<'PY'
import plistlib,sys
e=plistlib.load(open(sys.argv[1],"rb")); team,bid=sys.argv[2],sys.argv[3]
want={"application-identifier":f"{team}.{bid}","com.apple.developer.team-identifier":team,
      "aps-environment":"production","get-task-allow":False,"beta-reports-active":True,
      "com.apple.developer.applesignin":["Default"],"keychain-access-groups":[f"{team}.{bid}",f"{team}.{bid}.push"]}
bad=[f"{k}: {e.get(k)!r} != {v!r}" for k,v in want.items() if e.get(k)!=v]
extra=sorted(set(e)-set(want))
if bad or extra:
    print("\n".join(["  - "+b for b in bad]+["  - unexpected "+x for x in extra]),file=sys.stderr); sys.exit(1)
print("ok: entitlements "+", ".join(sorted(e)))
PY
}

# The notification content extension: embedded, its own id and version, and
# only the shared push keychain group beyond the profile's basics.
check_extension() {  # <CmuxMobileApp.app> [signed]
  local appex="$1/PlugIns/CmuxMobileNotificationContent.appex" info
  info="$appex/Info.plist"
  [[ -d "$appex" ]] || die "$1 has no notification content extension"
  [[ "$(plutil -extract CFBundleIdentifier raw "$info")" == "$ext_bundle_id" ]] || die "extension bundle id is not $ext_bundle_id"
  [[ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$info")" == com.apple.usernotifications.content-extension ]] \
    || die "the extension is not a notification content extension"
  [[ "$(plutil -extract CFBundleShortVersionString raw "$info")" == "$marketing" ]] || die "the extension's version differs from the app's"
  [[ "$(plutil -extract CFBundleVersion raw "$info")" == "$build_number" ]] || die "the extension's build number differs from the app's"
  [[ "${2:-}" == signed ]] || { echo "ok: notification content extension ($ext_bundle_id)"; return 0; }
  [[ "$(plutil -extract CmuxMobileKeychainGroup raw "$info")" == "$team.$bundle_id.push" ]] \
    || die "the extension's CmuxMobileKeychainGroup is not $team.$bundle_id.push"
  codesign -d --entitlements - --xml "$appex" 2>/dev/null > "$private/ext-ent-check.plist"
  python3 -I -c '
import plistlib,sys
e=plistlib.load(open(sys.argv[1],"rb")); team,bid,app=sys.argv[2],sys.argv[3],sys.argv[4]
want={"application-identifier":f"{team}.{bid}","com.apple.developer.team-identifier":team,
      "get-task-allow":False,"beta-reports-active":True,"keychain-access-groups":[f"{team}.{app}.push"]}
bad=[f"{k}: {e.get(k)!r} != {v!r}" for k,v in want.items() if e.get(k)!=v]
extra=sorted(set(e)-set(want))
if bad or extra:
    print("\n".join(["  - "+b for b in bad]+["  - unexpected "+x for x in extra]),file=sys.stderr); sys.exit(1)
print("ok: extension entitlements "+", ".join(sorted(e)))' "$private/ext-ent-check.plist" "$team" "$ext_bundle_id" "$bundle_id" \
    || die "$appex has the wrong entitlements"
}

# The notification service extension: embedded, its own id and version, and
# only the shared push keychain group beyond the profile's basics.
check_service_extension() {  # <CmuxMobileApp.app> [signed]
  local appex="$1/PlugIns/CmuxMobileNotificationService.appex" info
  info="$appex/Info.plist"
  [[ -d "$appex" ]] || die "$1 has no notification service extension"
  [[ "$(plutil -extract CFBundleIdentifier raw "$info")" == "$svc_bundle_id" ]] || die "service extension bundle id is not $svc_bundle_id"
  [[ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$info")" == com.apple.usernotifications.service ]] \
    || die "the service extension is not a notification service extension"
  [[ "$(plutil -extract CFBundleShortVersionString raw "$info")" == "$marketing" ]] || die "the service extension's version differs from the app's"
  [[ "$(plutil -extract CFBundleVersion raw "$info")" == "$build_number" ]] || die "the service extension's build number differs from the app's"
  [[ "$(plutil -extract CmuxMobileKeychainGroup raw "$info")" == "$team.$bundle_id.push" ]] || die "the service extension's keychain group is not $team.$bundle_id.push"
  [[ "${2:-}" == signed ]] || { echo "ok: notification service extension ($svc_bundle_id)"; return 0; }
  codesign -d --entitlements - --xml "$appex" 2>/dev/null > "$private/svc-ent-check.plist"
  python3 -I -c '
import plistlib,sys
e=plistlib.load(open(sys.argv[1],"rb")); team,bid,app=sys.argv[2],sys.argv[3],sys.argv[4]
want={"application-identifier":f"{team}.{bid}","com.apple.developer.team-identifier":team,
      "get-task-allow":False,"beta-reports-active":True,"keychain-access-groups":[f"{team}.{app}.push"]}
bad=[f"{k}: {e.get(k)!r} != {v!r}" for k,v in want.items() if e.get(k)!=v]
extra=sorted(set(e)-set(want))
if bad or extra:
    print("\n".join(["  - "+b for b in bad]+["  - unexpected "+x for x in extra]),file=sys.stderr); sys.exit(1)
print("ok: service extension entitlements "+", ".join(sorted(e)))' "$private/svc-ent-check.plist" "$team" "$svc_bundle_id" "$bundle_id" \
    || die "$appex has the wrong entitlements"
}

log "checks: archived app"
check_app "$archived_app"
check_extension "$archived_app"
check_service_extension "$archived_app"

ipa="" validated="not run" signing="unsigned (--unsigned)"
if [[ -n "$from_archive" ]]; then
  # --- Sign the unsigned archived app with the profile (no export step) ----
  # An unsigned archive carries no entitlements, so `-exportArchive` would ship
  # none. Sign with exactly the set check_entitlements requires instead.
  log "sign (profile \"$profile_name\", identity $identity)"
  stage="$work/stage"; rm -rf "$stage"; mkdir -p "$stage/Payload"
  ditto "$archived_app" "$stage/Payload/CmuxMobileApp.app"
  app="$stage/Payload/CmuxMobileApp.app"
  appexes=$(find "$app/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null | sort)
  [[ "$appexes" == "$app/PlugIns/CmuxMobileNotificationContent.appex"$'\n'"$app/PlugIns/CmuxMobileNotificationService.appex" ]] \
    || die "unexpected app extensions: $appexes (CmuxMobileNotificationContent.appex and CmuxMobileNotificationService.appex have profiles here)"
  cp "$profile_path" "$app/embedded.mobileprovision"
  python3 -I - "$private/sign-ent.plist" "$team" "$bundle_id" <<'PY'
import plistlib,sys
team,bid=sys.argv[2],sys.argv[3]
plistlib.dump({"application-identifier":f"{team}.{bid}","com.apple.developer.team-identifier":team,
  "aps-environment":"production","get-task-allow":False,"beta-reports-active":True,
  "com.apple.developer.applesignin":["Default"],"keychain-access-groups":[f"{team}.{bid}",f"{team}.{bid}.push"]},open(sys.argv[1],"wb"))
PY
  while IFS= read -r nested; do
    codesign --force --sign "$identity" --timestamp "$nested"
  done < <(find "$app" -depth \( -name '*.framework' -o -name '*.dylib' \) -print)
  content_appex="$app/PlugIns/CmuxMobileNotificationContent.appex"
  service_appex="$app/PlugIns/CmuxMobileNotificationService.appex"
  # The extensions first: each its own profile and the entitlements its check requires.
  cp "$svc_profile_path" "$service_appex/embedded.mobileprovision"
  python3 -I -c '
import plistlib,sys
team,bid,app=sys.argv[2],sys.argv[3],sys.argv[4]
plistlib.dump({"application-identifier":f"{team}.{bid}","com.apple.developer.team-identifier":team,
  "get-task-allow":False,"beta-reports-active":True,"keychain-access-groups":[f"{team}.{app}.push"]},open(sys.argv[1],"wb"))' \
    "$private/svc-ent.plist" "$team" "$svc_bundle_id" "$bundle_id"
  codesign --force --sign "$identity" --timestamp --generate-entitlement-der \
    --entitlements "$private/svc-ent.plist" "$service_appex"
  if [[ -n "$appexes" ]]; then
    cp "$ext_profile_path" "$content_appex/embedded.mobileprovision"
    python3 -I -c '
import plistlib,sys
team,bid,app=sys.argv[2],sys.argv[3],sys.argv[4]
plistlib.dump({"application-identifier":f"{team}.{bid}","com.apple.developer.team-identifier":team,
  "get-task-allow":False,"beta-reports-active":True,"keychain-access-groups":[f"{team}.{app}.push"]},open(sys.argv[1],"wb"))' \
      "$private/ext-ent.plist" "$team" "$ext_bundle_id" "$bundle_id"
    codesign --force --sign "$identity" --timestamp --generate-entitlement-der \
      --entitlements "$private/ext-ent.plist" "$content_appex"
  fi
  codesign --force --sign "$identity" --timestamp --generate-entitlement-der \
    --entitlements "$private/sign-ent.plist" "$app"
  ipa="$out/CmuxMobileApp.ipa"
  (cd "$stage" && zip -qry "$ipa" Payload)
  signing="distribution identity $identity, profile \"$profile_name\" ($profile_uuid), extension profiles \"$ext_profile_name\" ($ext_profile_uuid), \"$svc_profile_name\" ($svc_profile_uuid), signed from an unsigned archive"
elif [[ $unsigned == 0 ]]; then
  check_entitlements "$archived_app"
  check_extension "$archived_app" signed
  check_service_extension "$archived_app" signed
  # --- Export an App Store IPA ---------------------------------------------
  log "export (app-store-connect)"
  cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$identity</string>
  <key>provisioningProfiles</key><dict>
    <key>$bundle_id</key><string>$profile_uuid</string>
    <key>$ext_bundle_id</key><string>$ext_profile_uuid</string>
    <key>$svc_bundle_id</key><string>$svc_profile_uuid</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><$internal_only/>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" > "$out/logs/export.log" 2>&1 \
    || { grep -E "error" "$out/logs/export.log" | sort -u | head -20; die "export failed (logs/export.log)"; }
  ipa="$out/CmuxMobileApp.ipa"
  mv "$work/export/"*.ipa "$ipa"
  signing="distribution identity $identity, profile \"$profile_name\" ($profile_uuid), extension profiles \"$ext_profile_name\" ($ext_profile_uuid), \"$svc_profile_name\" ($svc_profile_uuid)"

fi
if [[ $unsigned == 0 ]]; then

  # --- Verify the IPA exactly as it would be uploaded ----------------------
  log "checks: exported IPA"
  rm -rf "$work/ipa" && mkdir -p "$work/ipa" && ditto -x -k "$ipa" "$work/ipa"
  check_app "$work/ipa/Payload/CmuxMobileApp.app"
  check_entitlements "$work/ipa/Payload/CmuxMobileApp.app"
  check_extension "$work/ipa/Payload/CmuxMobileApp.app" signed
  check_service_extension "$work/ipa/Payload/CmuxMobileApp.app" signed

  # --- Validate with Apple (no upload) -------------------------------------
  # altool reads the API key from a file: copy it out of the asc keychain item
  # into the private temp dir for this call only.
  write_p8() {
    if [[ $ci_asc == 1 ]]; then
      cp "$ASC_PRIVATE_KEY_PATH" "$private/AuthKey_$asc_key_id.p8"; chmod 600 "$private/AuthKey_$asc_key_id.p8"; return
    fi
    security find-generic-password -s asc -a "asc:credential:$asc_profile" -w 2>/dev/null \
      | python3 -I -c '
import json,sys,re
raw=sys.stdin.read().strip()
try:
    d=json.loads(raw); k=next((v for kk,v in d.items() if "private" in kk.lower() and "BEGIN" in str(v)),"")
except Exception:
    k=raw if "BEGIN PRIVATE KEY" in raw else ""
if not k: sys.exit(1)
open(sys.argv[1],"w").write(k if k.endswith("\n") else k+"\n")' "$private/AuthKey_$asc_key_id.p8" \
      || die "could not read the key for \"$asc_profile\" from the asc keychain item"
    chmod 600 "$private/AuthKey_$asc_key_id.p8"
  }
  if [[ $skip_validate == 0 ]]; then
    log "altool --validate-app"
    write_p8
    if xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$asc_key_id" --apiIssuer "$asc_issuer" \
         --p8-file-path "$private/AuthKey_$asc_key_id.p8" --output-format json > "$out/logs/validate.json" 2> "$out/logs/validate.log"; then
      validated="passed ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
    else
      cat "$out/logs/validate.json" "$out/logs/validate.log" | tail -30
      die "Apple validation failed (logs/validate.json)"
    fi
    echo "validation: $validated"
  else
    validated="skipped (--skip-validate)"
  fi

  if [[ $upload == 1 ]]; then
    log "UPLOAD to $app_name ($app_id)"
    [[ -f "$private/AuthKey_$asc_key_id.p8" ]] || write_p8
    xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$asc_key_id" --apiIssuer "$asc_issuer" \
      --p8-file-path "$private/AuthKey_$asc_key_id.p8" --output-format json > "$out/logs/upload.json" 2>&1 \
      || { tail -30 "$out/logs/upload.json"; die "upload failed"; }
    log "wait for App Store Connect to process $build_number"
    asc_ builds wait --app "$app_id" --build-number "$build_number" --platform IOS --fail-on-invalid --timeout 45m --output json > "$out/logs/process.json" 2>&1 \
      || { tail -20 "$out/logs/process.json"; die "build $build_number did not finish processing"; }
    if [[ -n "$what_to_test" ]]; then
      # App Store Connect makes the en-US entry on processing: update it.
      # Retries Apple 5xx; a failure only warns (the build is already uploaded).
      bash "$script_dir/set-test-notes.sh" "$out/logs/notes.json" -- \
        "${asc_cmd[@]}" builds test-notes update --app "$app_id" --build-number "$build_number" --platform IOS --locale en-US \
        --whats-new "$what_to_test" --output json
    fi
    notes+=("Uploaded to $app_name at $(date -u +%Y-%m-%dT%H:%M:%SZ); processed. Add What to Test notes from cmux-next-ios/verify/testflight-metadata.md.")
  fi
fi

# --- Manifest ---------------------------------------------------------------
{
  cat <<EOF
# cmux-next-ios TestFlight build $name

| | |
| --- | --- |
| Commit | \`$sha\` ($(git -C "$repo" log -1 --format='%s' "$sha")) |
| Built | $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(scutil --get LocalHostName 2>/dev/null || hostname), $(xcodebuild -version | head -1) |
| App Store Connect | "$app_name", app id $app_id, bundle \`$bundle_id\` |
| Version | $marketing ($build_number); $app_name had up to $max_marketing ($max_build) |
| Configuration | $config: -O, \`CMUX_MOBILE_PRODUCTION CMUX_MOBILE_TESTFLIGHT\`, no DEBUG; Stack project \`$stack_project\`; Cloud \`$cloud_api_base\` |
| Service | \`$api_base\` |
| Signing | $signing |
| Internal-only | $internal_only |
| Apple validation | $validated |
| Uploaded | $([[ $upload == 1 ]] && echo yes || echo "no (upload with --upload)") |
EOF
  [[ ${#notes[@]} == 0 ]] || printf '\n## Notes\n\n'
  for n in "${notes[@]+"${notes[@]}"}"; do echo "- $n"; done
} > "$out/MANIFEST.md"
rm -rf "$work"
log "done: $out"
cat "$out/MANIFEST.md"
