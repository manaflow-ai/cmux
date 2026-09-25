#!/usr/bin/env bash
# retry.sh <attempts> <delay-seconds> <command...>
# Gatekeeper reads fresh notarization tickets from Apple's CDN, which can lag
# notarytool's "Accepted" status by minutes (see notarize-computer-use-helper.sh).
set -uo pipefail
attempts="$1"; delay="$2"; shift 2
for ((i = 1; i <= attempts; i++)); do
  "$@" && exit 0
  echo "attempt $i/$attempts failed: $*"
  [ "$i" -lt "$attempts" ] && sleep "$delay"
done
exit 1
