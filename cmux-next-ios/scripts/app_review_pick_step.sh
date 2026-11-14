#!/usr/bin/env bash
# The App Review gate's "Pick the <family> simulator" step (ios-review-gate.yml),
# run before the device leg builds anything:
#
#   app_review_pick_step.sh FAMILY     (env: RESULTS, GITHUB_ENV; PICKER for tests)
#
# The picker (app_review_pick_simulator.py) exits 3 when the image has no
# simulator for FAMILY: the leg skips its build and leaves FAMILY.skipped.json,
# which the report reads as that family's result. Its UDID goes to GITHUB_ENV
# as UDID. Any other picker failure fails the leg, which then leaves no
# result, so the report blocks.
set +e
set -uo pipefail
family="$1"
picker="${PICKER:-$(dirname "$0")/app_review_pick_simulator.py}"
udid="$(python3 -I "$picker" --family "$family" --print-udid)"
code=$?
if [ "$code" -eq 0 ]; then
  echo "UDID=$udid" >> "$GITHUB_ENV"
elif [ "$code" -eq 3 ]; then
  echo "::notice::no $family simulator on this image; its size classes are covered by the Pro Max and iPad rotation tests"
  echo "{\"family\":\"$family\",\"skipped\":true}" > "$RESULTS/$family.skipped.json"
else
  echo "::error::the $family simulator pick failed (exit $code)" >&2
  exit "$code"
fi
