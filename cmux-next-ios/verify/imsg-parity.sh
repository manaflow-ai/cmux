#!/usr/bin/env bash
# Side-by-side behavior run: the iMessage team's lab host (REF, built from
# origin/feat-imsg-parity-gui) and Chief (OURS) on two headless simulators,
# each fed by its own identical conversation-sim (verify/imsg-sims.sh), the
# same real HID touches sent to both at once through `axe`. Screenshots per
# state, recordings for motion, side-by-side sheets with a pixel diff.
# usage: verify/imsg-parity.sh <sim-checkout> <ref-udid> <ours-udid> <dark|light> <out-dir>
#   CONTENT_SIZE=accessibility-extra-large for Dynamic Type.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$1
source "$here/imsg-pair.sh"
"$here/imsg-sims.sh" "$root" >/dev/null
# The last rows are the same on every run: John's three messages.
for port in 4870 4871; do
  for text in "Latest build is green on both Macs" "Can you check the release notes before I tag it?" "ok"; do
    curl -sf -X POST "127.0.0.1:$port/admin/say?conversation=direct&sender=john&text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$text")" >/dev/null
  done
done
pair_setup "$2" "$3" "$4" "$5"
sbs() { python3 "$here/imsg-sbs.py" "$OUT" "$@"; }
admin() { for port in 4870 4871; do curl -sf -X POST "127.0.0.1:$port$1" >/dev/null; done; }

pair_launch
sleep 8
shot 01-open

# Scroll: a slow drag down puts rows under the header; then flick, rest, bottom.
rec_start scroll
both drag --start-x 220 --start-y 380 --end-x 220 --end-y 640 --duration 0.9 --steps 90
sleep 1.2; shot 02-under-header
both drag --start-x 220 --start-y 250 --end-x 220 --end-y 900 --duration 0.12 --steps 8
sleep 0.25; shot 03-flick-moving
sleep 3; shot 04-flick-rest
for _ in 1 2 3 4; do both drag --start-x 220 --start-y 850 --end-x 220 --end-y 200 --duration 0.1 --steps 8; sleep 0.4; done
sleep 2.5; shot 05-bottom
rec_stop

# Send times: a left drag across the transcript. The drawer opens past its
# peek distance; the recording's deepest frame is the held state.
rec_start timestamps
both drag --start-x 390 --start-y 600 --end-x 80 --end-y 600 --duration 1.2 --steps 80
sleep 2; shot 07-timestamps-released
rec_stop
python3 "$here/imsg-peak.py" "$OUT" timestamps 06-timestamps-held

# Long press on John's newest message: menu and tapbacks, then the heart.
both touch -x 45 -y 851 --down --up --delay 1.2
sleep 1.2; shot 08-longpress
both tap -x 52 -y 560
sleep 2; shot 09-heart
# Tapback badge passing under the header.
both drag --start-x 220 --start-y 300 --end-x 220 --end-y 900 --duration 1.4 --steps 120
sleep 1.5; shot 10-heart-under-header
for _ in 1 2 3; do both drag --start-x 220 --start-y 850 --end-x 220 --end-y 200 --duration 0.1 --steps 8; sleep 0.4; done
sleep 2

# Reply: right swipe on John's newest message, type, send, the thread.
rec_start reply
both drag --start-x 45 --start-y 851 --end-x 260 --end-y 851 --duration 0.35 --steps 25
sleep 1.5; shot 11-reply-mode
both tap -x 230 -y 908; sleep 0.8
both type 'on it'
sleep 0.8; shot 12-reply-typed
both tap -x 386 -y 908
sleep 3; shot 13-reply-sent
both tap -x 397 -y 84
sleep 1.8; shot 14-reply-in-transcript
rec_stop

# Keyboard: software keyboard up, type, send; interactive dismiss.
rec_start keyboard
both tap -x 230 -y 908
sleep 1.5; shot 15-composer-focused
both type 'Thanks, tagging after lunch'
sleep 1; shot 16-composer-typed
both tap -x 386 -y 908
sleep 3; shot 17-sent
both drag --start-x 220 --start-y 300 --end-x 220 --end-y 940 --duration 1.2 --steps 100
sleep 1.5; shot 18-keyboard-dragged
rec_stop

# Incoming while scrolled up, typing indicator, delivery.
both drag --start-x 220 --start-y 380 --end-x 220 --end-y 800 --duration 0.6 --steps 60
sleep 1.5
admin "/admin/say?conversation=direct&sender=john&text=Tagged%201.4.0"
sleep 2; shot 19-incoming-scrolled-up
for _ in 1 2 3; do both drag --start-x 220 --start-y 850 --end-x 220 --end-y 200 --duration 0.1 --steps 8; sleep 0.4; done
admin "/admin/typing?conversation=direct&sender=john&on=1"
sleep 2; shot 20-typing
admin "/admin/typing?conversation=direct&sender=john&on=0"

# Not delivered: every send fails, then retry succeeds.
for port in 4870 4871; do curl -sf -X POST "127.0.0.1:$port/admin/knobs" -d '{"failRate":1}' >/dev/null; done
both tap -x 230 -y 908; sleep 0.8
both type 'this one fails'
sleep 0.5; both tap -x 386 -y 908
sleep 4; shot 21-not-delivered
for port in 4870 4871; do curl -sf -X POST "127.0.0.1:$port/admin/knobs" -d '{"failRate":0}' >/dev/null; done

# Header tap: the details page.
both tap -x 220 -y 92
sleep 2; shot 22-details
both tap -x 42 -y 82
sleep 1.5; shot 23-details-closed

# Left-edge swipe back. Chief pops to Home; the lab's conversation is the
# root of its navigation controller, so nothing pops there. The deepest
# frame of the recording is the interactive pop in progress.
rec_start edge
both drag --start-x 1 --start-y 500 --end-x 300 --end-y 500 --duration 1.0 --steps 70
sleep 2; shot 25-edge-released
rec_stop
python3 "$here/imsg-peak.py" "$OUT" edge 24-edge-held

sbs 01-open 02-under-header 03-flick-moving 04-flick-rest 05-bottom 06-timestamps-held 07-timestamps-released \
  08-longpress 09-heart 10-heart-under-header 11-reply-mode 12-reply-typed 13-reply-sent 14-reply-in-transcript \
  15-composer-focused 16-composer-typed 17-sent 18-keyboard-dragged 19-incoming-scrolled-up 20-typing \
  21-not-delivered 22-details 23-details-closed 24-edge-held 25-edge-released
for r in scroll timestamps reply keyboard edge; do strip "$r" 6; done
