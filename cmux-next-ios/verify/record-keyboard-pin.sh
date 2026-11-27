#!/usr/bin/env bash
# Composer keyboard pinning (verify/keyboard-pin.md): open a composer with a
# DEBUG demo, drive the keyboard with real HID touches (AXe) while `simctl io
# recordVideo` records and the app writes its per-frame trace
# (-cmux-mobile-kbd-pin-trace), then report the trace and split the frames.
#
# usage: verify/record-keyboard-pin.sh <udid> <out-dir> <label> <demo> [step ...]
#   demo: chief-open | ws-terminal-idle | kbd-chat | kbd-tab
#   steps (default: show swipe show drag show fling):
#     show     tap the composer field (the keyboard comes up)
#     swipe    swipe down on the composer (keyboard away, not tracked)
#     drag     drag the content slowly from the middle to the screen's bottom
#              (interactive dismissal)
#     fling    the same drag, fast (released while moving)
#     peek     drag slowly 70 pt into the keyboard and let go (UIKit calls the
#              dismissal off and the keyboard springs back up)
#     hwkey    press a key on a hardware keyboard (the software keyboard
#              gives way to the hardware one)
#     wait     1.6 s
# Needs: the app installed (bundle id in $BUNDLE, default dev.cmux.mobile),
# AXe, ffmpeg. After each step the script waits (bounded) until the app's
# trace shows the keyboard and the field holding still.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
udid=$1 dir=$2 label=$3 demo=$4
shift 4
steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(show swipe show drag show fling)
bundle=${BUNDLE:-dev.cmux.mobile}
mkdir -p "$dir"
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
trace="$data/Documents/kbd-pin-trace.txt"
rm -f "$trace"
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" "$bundle" \
  -cmuxMobile.setupComplete YES -cmux-mobile-demo "$demo" -cmux-mobile-kbd-pin-trace >/dev/null
sleep 6

# The field's centre and the window's size, from the trace's last frame.
field_xy() {
  tail -n 400 "$trace" | python3 -I -c '
import re, sys
for line in reversed(sys.stdin.read().splitlines()):
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    if "fy" in kv:
        print(int(float(kv["fx"]) + min(float(kv["fw"]) / 2, 120)), int((float(kv["fy"]) + float(kv["fb"])) / 2), kv["win"].replace("x", " "))
        break'
}

# Bounded wait until the trace's last 12 frames agree on the keyboard and the
# field (or 6 s pass): a step's motion has finished.
settle() {
  python3 -I - "$trace" <<'PY'
import re, sys, time
deadline = time.time() + 6
while time.time() < deadline:
    time.sleep(0.25)
    lines = [l for l in open(sys.argv[1]).read().splitlines()[-40:] if "ev=" not in l][-12:]
    vals = {tuple(dict(re.findall(r"(\w+)=(\S+)", l)).get(k) for k in ("kb", "fb")) for l in lines}
    if len(lines) == 12 and len(vals) == 1:
        break
PY
}
# The drawn keyboard's top in the trace's last frame (the window's bottom when none).
kb_top() {
  tail -n 5 "$trace" | python3 -I -c '
import re, sys
for line in reversed(sys.stdin.read().splitlines()):
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    if "win" in kv:
        print(int(float(kv["kb"])) if kv.get("kb", "-") != "-" else int(float(kv["win"].split("x")[1])))
        break'
}

read -r fx fy ww wh < <(field_xy) || { echo "no composer field in the trace" >&2; tail -3 "$trace" >&2; exit 1; }
echo "field at $fx,$fy window ${ww}x$wh"

log=$(mktemp)
for _ in $(seq 60); do
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/$label.mp4" >"$log" 2>&1 &
  rec=$!
  for _ in $(seq 50); do grep -q "Recording started" "$log" && break; kill -0 $rec 2>/dev/null || break; sleep 0.1; done
  grep -q "Recording started" "$log" && break
  kill -INT $rec 2>/dev/null || true; wait $rec 2>/dev/null || true
  sleep 2
done
grep -q "Recording started" "$log" || { cat "$log"; exit 1; }
trap 'kill -INT $rec 2>/dev/null || true' EXIT
echo "t=$(python3 -c 'import time;print(time.time())') rec-start" >"$dir/$label.steps.txt"
sleep 0.8

midx=$((ww / 2)) top=$((wh * 28 / 100))
n=0
xcrun simctl io "$udid" screenshot "$dir/$label-00-rest.png" >/dev/null 2>&1 || true
for step in "${steps[@]}"; do
  n=$((n + 1))
  read -r fx fy _ _ < <(field_xy)
  echo "t=$(python3 -c 'import time;print(time.time())') $step field=$fx,$fy" >>"$dir/$label.steps.txt"
  case $step in
    show) axe tap -x "$fx" -y "$fy" --udid "$udid" >/dev/null ;;
    swipe) axe drag --start-x "$fx" --start-y "$fy" --end-x "$fx" --end-y $((fy + 160)) --duration 0.25 --steps 15 --udid "$udid" >/dev/null ;;
    drag) axe drag --start-x "$midx" --start-y "$top" --end-x "$midx" --end-y $((wh - 4)) --duration 1.6 --steps 96 --udid "$udid" >/dev/null ;;
    fling) axe drag --start-x "$midx" --start-y "$top" --end-x "$midx" --end-y $((wh - 4)) --duration 0.18 --steps 11 --udid "$udid" >/dev/null ;;
    peek) k=$(kb_top); axe drag --start-x "$midx" --start-y "$top" --end-x "$midx" --end-y $((k + 70)) --duration 1.4 --steps 84 --udid "$udid" >/dev/null ;;
    hwkey) axe key 4 --udid "$udid" >/dev/null ;;  # HID 'a'
    wait) ;;
    *) echo "unknown step $step" >&2; exit 2 ;;
  esac
  sleep 0.5
  settle
  # The settled screen after each step (exact pixels, unlike the video).
  xcrun simctl io "$udid" screenshot "$dir/$label-$(printf %02d $n)-$step.png" >/dev/null 2>&1 || true
done
kill -INT $rec; wait $rec || true
trap - EXIT
cp "$trace" "$dir/$label.trace.txt"
python3 -I "$(dirname "$0")/scripts/kbd_pin_trace.py" "$dir/$label.trace.txt" | tee "$dir/$label.summary.txt"
xcrun simctl io "$udid" screenshot "$dir/$label-end.png" >/dev/null 2>&1 || true
rm -rf "$dir/$label-frames"
mkdir -p "$dir/$label-frames"
ffmpeg -loglevel error -i "$dir/$label.mp4" -vf "fps=60,scale=402:-1" "$dir/$label-frames/%04d.jpg"
echo "$dir/$label.mp4 $(ls "$dir/$label-frames" | wc -l | tr -d ' ') frames"
