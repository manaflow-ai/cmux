#!/usr/bin/env bash
# Chat dogfood helpers (verify/chat-dogfood.md). Source it: `source verify/chatdog.sh`, then
# D=<udid> launch / gochat / tap x y / tapl LABEL / ui / shot NAME / recstart NAME / recstop / frames NAME / row OUT A B...
# Taps are real HID touches through axe, in points. Headless simulators only.
CHATDOG_DIR=${CHATDOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
D26=${D26:-}
D27=${D27:-}
D=${D:-$D26}
EV=${EV:-$CHATDOG_DIR/evidence/$(date +%F)/chatdog}
mkdir -p $EV
launch() { xcrun simctl terminate $D dev.cmux.mobile >/dev/null 2>&1; SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch $D dev.cmux.mobile "$@" >/dev/null; }
shot() { xcrun simctl io $D screenshot "$EV/$1.png" >/dev/null 2>&1; sips -Z 900 "$EV/$1.png" --out "$EV/$1.s.png" >/dev/null 2>&1; echo "$EV/$1.s.png"; }
tap() { axe tap -x $1 -y $2 --udid $D >/dev/null; }
tapl() { axe tap --label "$1" --udid $D "${@:2}"; }
ui() { axe describe-ui --udid $D | python3 "$CHATDOG_DIR/scripts/chatdog_ui.py"; }
recstart() { rm -f /tmp/chatdog-rec.log; xcrun simctl io $D recordVideo --codec h264 --force "$EV/$1.mp4" >/tmp/chatdog-rec.log 2>&1 & echo $! > /tmp/chatdog-rec.pid; until grep -q "Recording started" /tmp/chatdog-rec.log; do sleep 0.1; done; }
recstop() { kill -INT $(cat /tmp/chatdog-rec.pid); while kill -0 $(cat /tmp/chatdog-rec.pid) 2>/dev/null; do sleep 0.2; done; }
frames() { rm -rf "$EV/$1-frames"; mkdir -p "$EV/$1-frames"; ffmpeg -loglevel error -y -i "$EV/$1.mp4" -vf "fps=${2:-2},scale=300:-1" "$EV/$1-frames/f%03d.png"; ls "$EV/$1-frames" | wc -l; }
sheet() { python3 "$CHATDOG_DIR/scripts/chatdog_sheet.py" "$EV/$1-frames" "$EV/$1-sheet.png" ${2:-1} ${3:-8}; }
gochat() { launch; sleep 3; axe tap --label "${1:-Claude · cmux, 3:42 PM, Refactor transport layer, Needs you}" --udid $D >/dev/null 2>&1 || tap 200 357; sleep 2; }
row() { o=$1; shift; python3 "$CHATDOG_DIR/scripts/chatdog_row.py" $EV/$o.png $(for n in "$@"; do echo $EV/$n.s.png; done); echo $EV/$o.png; }
