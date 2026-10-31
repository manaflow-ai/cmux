#!/usr/bin/env bash
# Record the team icon editor on a headless simulator (no Simulator.app
# window): Custom, type a letter on the software keyboard, switch to the emoji
# keyboard and pick an emoji (it replaces the letter), then None, then
# Automatic. Taps go through AXe (`axe tap`) on the on-screen keyboard keys,
# never `axe type`: HID typing attaches a hardware keyboard and hides the
# software keyboard for the rest of the simulator's life.
# usage: verify/glyph-flow.sh <udid> <out.mp4> <light|dark>
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 out=$2 appearance=$3
xcrun simctl ui "$udid" appearance "$appearance"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
export SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
mkdir -p "$(dirname "$out")"
# AXe's screenshot-based recorder: `simctl io recordVideo` allows one
# recording per host, which parallel agents often hold.
axe record-video --udid "$udid" --fps 30 --output "$out" >/dev/null 2>&1 &
rec=$!
sleep 1   # recorder warm-up; pacing only
xcrun simctl launch "$udid" dev.cmux.mobile -cmuxMobile.setupComplete YES -cmux-mobile-tab workspaces -cmux-mobile-demo editor >/dev/null
tap() { axe tap --label "$1" --wait-timeout 15 --post-delay 1.2 --udid "$udid" >/dev/null; }
key() { axe tap --label "$1" --element-type Button --wait-timeout 5 --post-delay 1.2 --udid "$udid" >/dev/null; }
tap Custom
# First keyboard use on a fresh simulator shows the slide-to-type tip.
axe tap --label Continue --element-type Button --wait-timeout 2 --post-delay 0.8 --udid "$udid" >/dev/null 2>&1 || true
key k
key Emoji
emoji=$(axe describe-ui --udid "$udid" 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
def walk(n):
    l, f = n.get("AXLabel") or "", n.get("frame") or {}
    if n.get("type") == "Button" and len(l) <= 2 and l and ord(l[0]) > 0x2000 and 0 < f.get("x", -1) < 360:
        print(l, round(f["x"] + f["width"] / 2), round(f["y"] + f["height"] / 2)); sys.exit(0)
    for c in n.get("children", []): walk(c)
for n in (d if isinstance(d, list) else [d]): walk(n)
')
read -r emoji ex ey <<<"$emoji"
axe tap -x "$ex" -y "$ey" --post-delay 1.2 --udid "$udid" >/dev/null
tap None
tap Automatic
sleep 1   # hold the last frame in the recording
kill -INT "$rec"
wait "$rec" || true
echo "$out ($emoji)"
