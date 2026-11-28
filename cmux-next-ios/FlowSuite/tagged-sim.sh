#!/usr/bin/env bash
# One Simulator per agent tag, so several agents can test on one Mac at once.
# Aziz's parallel-simulator notes (cmuxterm-hq skills/ios/ios-dogfood, 195e06e9da
# and 963409f0ab), as a script instead of prose.
#
#   tagged-sim.sh create TAG   create and boot "cmux-TAG"; prints its UDID
#   tagged-sim.sh find TAG     prints the UDID of "cmux-TAG" (exact name match)
#   tagged-sim.sh open TAG     opens its window in the background (-g, -CurrentDeviceUDID)
#   tagged-sim.sh delete TAG   deletes it; do this when the task ends
#   tagged-sim.sh self-test    checks the guards below; runs anywhere, no Xcode
#
# Rules it enforces:
# - Pass the UDID it prints (never `booted`, a device name or a default device)
#   to every simctl, `xcodebuild -destination id=`, install, launch, screenshot,
#   video and push command.
# - Never touch a device with another tag: find and delete match "cmux-TAG (" exactly.
# - It does not change who may boot a local simulator: local runs still need
#   authorization and at most three booted. The fleet step
#   (scripts/ci/cmux-next-ios-sim.sh through cmux-ci) is preferred.
set -euo pipefail

MAX_BOOTED=3

valid_tag() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,15}$ ]] && [[ "$1" != booted ]]
}

sim_name() { printf 'cmux-%s' "$1"; }

# Reads `simctl list devices` text on stdin; prints the UDID of exactly "cmux-TAG (".
udid_from_list() {
  local name; name="$(sim_name "$1")"
  grep -F "    $name (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' | head -1
}

need_xcode() {
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"  # simctl fails on the CLT
  command -v xcrun >/dev/null || { echo "tagged-sim: xcrun not found (macOS with Xcode only)" >&2; exit 2; }
}

cmd="${1:-}"; tag="${2:-}"
case "$cmd" in
  self-test)
    fail=0
    for t in ab12 lane-18 x; do valid_tag "$t" || { echo "rejects good tag $t" >&2; fail=1; }; done
    for t in "" booted Booted "a b" "../x" "-lead" "much-too-long-tag-name"; do
      valid_tag "$t" && { echo "accepts bad tag '$t'" >&2; fail=1; }
    done
    list=$'== Devices ==\n-- iOS 26.5 --\n    cmux-ab (11111111-1111-1111-1111-111111111111) (Booted)\n    cmux-ab12 (22222222-2222-2222-2222-222222222222) (Shutdown)\n    iPhone 17 Pro (33333333-3333-3333-3333-333333333333) (Booted)'
    [[ "$(udid_from_list ab <<<"$list")" == 11111111-1111-1111-1111-111111111111 ]] || { echo "find ab picked the wrong device" >&2; fail=1; }
    [[ "$(udid_from_list ab12 <<<"$list")" == 22222222-2222-2222-2222-222222222222 ]] || { echo "find ab12 picked the wrong device" >&2; fail=1; }
    [[ -z "$(udid_from_list zz <<<"$list")" ]] || { echo "find zz matched another tag" >&2; fail=1; }
    (( fail == 0 )) && echo "tagged-sim self-test ok"
    exit "$fail"
    ;;
  create|find|open|delete) ;;
  *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac

valid_tag "$tag" || { echo "tagged-sim: tag must be 1-16 of [a-z0-9-], not 'booted' (got '$tag')" >&2; exit 2; }
need_xcode
name="$(sim_name "$tag")"
existing="$(xcrun simctl list devices | udid_from_list "$tag" || true)"

case "$cmd" in
  create)
    if [[ -n "$existing" ]]; then echo "$existing"; exit 0; fi
    booted="$(xcrun simctl list devices booted | grep -c '(Booted)' || true)"
    (( booted < MAX_BOOTED )) || { echo "tagged-sim: $booted simulators booted already (limit $MAX_BOOTED)" >&2; exit 1; }
    runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]][-1])')"
    udid="$(xcrun simctl create "$name" "${CMUX_SIM_DEVICE_TYPE:-iPhone 17 Pro}" "$runtime")"
    [[ -n "$udid" ]] || { echo "tagged-sim: simctl create failed" >&2; exit 1; }
    xcrun simctl boot "$udid"
    echo "$udid"
    ;;
  find)
    [[ -n "$existing" ]] || { echo "tagged-sim: no simulator named $name" >&2; exit 1; }
    echo "$existing"
    ;;
  open)
    [[ -n "$existing" ]] || { echo "tagged-sim: no simulator named $name" >&2; exit 1; }
    open -gna Simulator --args -CurrentDeviceUDID "$existing"
    ;;
  delete)
    [[ -n "$existing" ]] || exit 0
    xcrun simctl delete "$existing"
    ;;
esac
