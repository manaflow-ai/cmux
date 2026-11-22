#!/usr/bin/env bash
# App Review for a processed build of an App Store Connect app record: attach the
# build to its App Store version, validate the version, and submit it for review.
# Written for cmux INTERNAL (dev.cmux.app.internal, app 6791408425), whose
# submittable builds come from ios-internal-nightly.yml (`submittable: true`) and
# are submitted by ios-internal-submit.yml; nothing here is specific to one app.
# The steps are those of main's ios/scripts/validate-app-store-release.sh
# (--prepare-submission, --submit --confirm-submit) for the retired classic app.
#
# usage: cmux-next-ios/scripts/asc_submit_review.sh attach --app ID --version X.Y.Z --build-number N
#        cmux-next-ios/scripts/asc_submit_review.sh submit --app ID --version X.Y.Z --build-number N
#            (--dry-run | --confirm-submit)
#
#   attach   find the processed build (version X.Y.Z, build N) and attach it to the
#            App Store version X.Y.Z, which must already exist in App Store Connect
#   submit   attach again (a no-op when it is attached), `asc validate --strict`, then
#            `asc review submit`: --dry-run previews it, --confirm-submit submits.
#            Submitting is a person's step: only ios-internal-submit.yml, dispatched
#            by hand with its confirm input, passes --confirm-submit.
#
# Auth: the asc CLI's environment (ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

cmd=${1:-}; [[ $# -gt 0 ]] && shift
app="" version="" build_number="" dry_run=0 confirm=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app=${2:-}; shift 2 ;;
    --version) version=${2:-}; shift 2 ;;
    --build-number) build_number=${2:-}; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --confirm-submit) confirm=1; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$cmd" in
  attach) [[ $dry_run == 0 && $confirm == 0 ]] || die "attach takes no --dry-run or --confirm-submit" ;;
  submit) [[ $((dry_run + confirm)) == 1 ]] || die "submit needs exactly one of --dry-run or --confirm-submit" ;;
  -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
  *) die "the first argument must be attach or submit" ;;
esac
[[ "$app" =~ ^[0-9]+$ ]] || die "--app must be the numeric App Store Connect app id"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "--version must be X.Y.Z, got '$version'"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "--build-number must be numeric, got '$build_number'"
command -v asc >/dev/null || die "the asc CLI is required"

# One JSON document on stdin (asc may append warnings): the first item's id.
first_id() {
  python3 -I -c '
import json, sys
body = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())[0]
data = body.get("data") if isinstance(body, dict) else body
data = data if isinstance(data, list) else ([data] if isinstance(data, dict) else [])
print(data[0].get("id", "") if data else "")'
}

# asc 5 names the build selector --build-id; older Homebrew bottles name it --build.
build_flag=--build
if asc versions attach-build --help 2>&1 | grep -q -- '--build-id'; then build_flag=--build-id; fi

build_id=$(asc builds info --app "$app" --build-number "$build_number" --version "$version" --platform IOS --output json | first_id)
[[ -n "$build_id" ]] || die "app $app has no build $version ($build_number)"
version_id=$(asc versions list --app "$app" --version "$version" --platform IOS --output json | first_id)
[[ -n "$version_id" ]] || die "app $app has no App Store version $version: create it in App Store Connect first"
note "attach build $build_number ($build_id) to App Store version $version ($version_id) of app $app"
asc versions attach-build --version-id "$version_id" "$build_flag" "$build_id"
[[ $cmd == submit ]] || exit 0

note "asc validate --strict: app $app, version $version"
asc validate --app "$app" --version "$version" --platform IOS --strict --output table

submit=(review submit --app "$app" --version "$version" "$build_flag" "$build_id" --platform IOS --output table)
if [[ $dry_run == 1 ]]; then
  note "preview: submit $version ($build_number) of app $app for App Review (--dry-run)"
  asc "${submit[@]}" --dry-run
else
  note "SUBMIT $version ($build_number) of app $app for App Review"
  asc "${submit[@]}" --confirm
fi
