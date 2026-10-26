#!/usr/bin/env bash
# Records the team management demo (DemoDriver `teams` and `teams-blocked`,
# mock mode) from a built Demo simulator app, e.g. the app zip in the
# evidence of `cmux-ci run --class simulator --script
# scripts/ci/cmux-next-ios-sim.sh --arg test`. Fleet or mini only, never the
# person's Mac. The script uses its own simulator device set and deletes it
# when it is done.
#
#   verify/team-capture.sh CmuxMobileApp.app OUT_DIR
#
# OUT_DIR gets teams.mp4, teams-blocked.mp4 and one screenshot per step:
# drawer with roles, admin page, rename dialog, renamed, member page,
# delete confirmation, after delete, and a delete refused for an active
# subscription.
set -euo pipefail
app="$1"; out="$2"
mkdir -p "$out"
sims="$(mktemp -d "${TMPDIR:-/tmp}/team-capture-sims.XXXXXX")"
simctl() { xcrun simctl --set "$sims" "$@"; }
cleanup() { simctl shutdown all >/dev/null 2>&1 || true; simctl delete all >/dev/null 2>&1 || true; rm -rf "$sims"; }
trap cleanup EXIT
read -r runtime device_type < <(xcrun simctl list -j runtimes devicetypes | python3 -c '
import json, sys
d = json.load(sys.stdin)
rts = sorted((r for r in d["runtimes"] if r.get("isAvailable") and r.get("platform") == "iOS"), key=lambda r: [int(x) for x in r["version"].split(".")])
rt = rts[-1]
names = {t["name"]: t["identifier"] for t in rt.get("supportedDeviceTypes", [])}
print(rt["identifier"], next((names[n] for n in ("iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro") if n in names), [v for k, v in names.items() if k.startswith("iPhone")][-1]))
')
udid="$(simctl create team-capture "$device_type" "$runtime")"
simctl boot "$udid"
simctl bootstatus "$udid" -b >/dev/null
simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
simctl install "$udid" "$app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
marker="$(simctl get_app_container "$udid" "$bundle_id" data)/Documents/demo-step.txt"
step() { cat "$marker" 2>/dev/null || true; }

run() { # name demo steps... [-- launch args]
  local name=$1 demo=$2; shift 2
  local steps=() extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do steps+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && { shift; extra=("$@"); }
  rm -f "$marker"
  simctl io "$udid" recordVideo --codec h264 --force "$out/$name.mp4" >/dev/null 2>&1 &
  local rec=$! s deadline
  SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 simctl launch "$udid" "$bundle_id" -cmuxMobile.setupComplete YES -cmux-mobile-no-restore \
    -cmux-mobile-demo "$demo" ${extra[@]+"${extra[@]}"} >/dev/null
  # Each step's mark, then 1.2 s for its transition (the demo holds a step 3 s).
  for s in "${steps[@]}" done; do
    deadline=$((SECONDS + 60))
    until [[ "$(step)" == "$s" ]] || (( SECONDS > deadline )); do sleep 0.2; done
    [[ "$(step)" == "$s" ]] || { echo "team-capture: step $s never came (last: $(step))" >&2; break; }
    [[ "$s" == done ]] && break
    sleep 1.2
    simctl io "$udid" screenshot "$out/$name-$s.png" >/dev/null
    echo "team-capture: $name-$s.png"
  done
  kill -INT "$rec" 2>/dev/null || true
  wait "$rec" 2>/dev/null || true
  simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
}
run teams teams 1-sidebar-roles 2-admin-page 3-rename-dialog 4-renamed 5-member-page 6-delete-dialog 7-deleted 8-sidebar-after-delete
run teams-blocked teams-blocked 1-admin-page 2-delete-dialog 3-refused -- -cmux-mobile-mock-team-subscribed
simctl spawn "$udid" log show --last 10m --style compact --predicate 'process == "CmuxMobileApp"' > "$out/app-log.txt" 2>/dev/null || true
