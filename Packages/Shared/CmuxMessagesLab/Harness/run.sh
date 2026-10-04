#!/bin/sh
# Differential harness: run the scripted conversation in catalyst/ and
# appkit-port/ (offscreen, virtual clock, never key), then compare.
#   tools/diff-harness/run.sh [OUT]            frames + pixel captures + report
#   CATALYST_APP=... APPKIT_APP=... to use other builds.
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/messageslab-diff}"
CAT="${CATALYST_APP:-/tmp/messageslab-appkit-port/catalyst-dd/Build/Products/Release-maccatalyst/MessagesLabCatalyst.app}"
APK="${APPKIT_APP:-appkit-port/dist/MessagesLabAppKitPort.app}"
PY="${PYTHON:-/tmp/imsg/venv/bin/python}"
rm -rf "$OUT"; mkdir -p "$OUT"
open -g -n -W "$CAT" --args -ApplePersistenceIgnoreState YES --diff-harness "$OUT/catalyst" &
open -g -n -W "$APK" --args -ApplePersistenceIgnoreState YES --diff-harness "$OUT/appkit-port" &
wait
"$PY" tools/diff-harness/diff.py "$OUT/catalyst" "$OUT/appkit-port" --md "$OUT/report.md" --json "$OUT/report.json" --diffs "$OUT/pixdiff"
