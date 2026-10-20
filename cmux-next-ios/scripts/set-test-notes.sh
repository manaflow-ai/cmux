#!/bin/bash
# Sets a TestFlight build's "What to Test" after upload; never fails the build.
#
#   set-test-notes.sh <log.json> -- <asc builds test-notes update ...>
#
# The build is already uploaded and processed when this runs, so a notes failure
# is a ::warning::, not an error (run 39421191207 went red on one Apple 500).
# An App Store Connect 5xx is retried, 3 tries in all, after the waits in
# CMUX_MOBILE_NOTES_BACKOFF_SECONDS (default "10 30"); any other failure is not retried.
set -uo pipefail

log=$1
shift
[[ ${1:-} == -- ]] && shift
read -r -a waits <<< "${CMUX_MOBILE_NOTES_BACKOFF_SECONDS:-10 30}"

try=1
while :; do
  if "$@" > "$log" 2>&1; then
    [[ $try == 1 ]] || echo "What to Test set on try $try."
    exit 0
  fi
  if (( try >= 3 )) || ! grep -Eq '\(status 5[0-9]{2}\)|status(Code)?"?: ?"?5[0-9]{2}' "$log"; then
    tail -20 "$log" >&2
    echo "::warning::could not set What to Test after $try tries; the build is uploaded. Set it in App Store Connect."
    exit 0
  fi
  wait=${waits[try-1]:-30}
  echo "App Store Connect answered 5xx to the notes call (try $try); retrying in ${wait}s."
  sleep "$wait"
  try=$((try + 1))
done
