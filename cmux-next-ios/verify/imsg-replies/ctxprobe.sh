#!/bin/bash
# Probe: does Messages (ReplyOn) draw reply quotes + thread lines in its transcript?
# Seeds the simulated chats with HID typing on <udid>, replies via long-press > Reply.
U=$1; A=~/.local/bin/axe
xcrun simctl terminate $U com.apple.MobileSMS 2>/dev/null
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$HOME/imsgreply/ReplyOn.dylib xcrun simctl launch $U com.apple.MobileSMS >/dev/null
sleep 3
say() { $A tap --label Message --element-type TextField --wait-timeout 6 --udid $U >/dev/null 2>&1; sleep 0.4; $A batch --udid $U --step "type '$1'" --step "sleep 0.5" --step "key 40" --step "sleep 0.8" >/dev/null; }
$A tap -x 220 -y 210 --udid $U >/dev/null; sleep 1.5
say "How about the cloud dogfooding"
say "Do you know how to do this properly"
$A tap --label Back --element-type Button --udid $U >/dev/null; sleep 1.2
$A tap -x 220 -y 245 --udid $U >/dev/null; sleep 1.5
say "Ill merge ok"
# keyboard down
$A swipe --start-x 220 --start-y 300 --end-x 220 --end-y 700 --duration 0.2 --udid $U >/dev/null 2>&1; sleep 0.8
center() { $A describe-ui --udid $U 2>/dev/null | python3 -c '
import json,sys
t=sys.argv[1]; best=None
def walk(n):
  global best
  l=n.get("AXLabel") or ""; v=n.get("AXValue") or ""; f=n.get("frame")
  if (t in l or t in v) and f and f["width"]>0:
    a=f["width"]*f["height"]
    if best is None or a<best[0]: best=(a,f)
  for c in n.get("children",[]): walk(c)
for n in json.load(sys.stdin): walk(n)
if best: f=best[1]; print(round(f["x"]+f["width"]/2), round(f["y"]+f["height"]/2))' "$1"; }
reply() { local c=$(center "$1"); $A touch -x ${c% *} -y ${c#* } --down --up --delay 1.0 --udid $U >/dev/null; sleep 1.2
  $A tap --label Reply --udid $U >/dev/null; sleep 1.5
  $A batch --udid $U --step "type '$2'" --step "sleep 0.5" >/dev/null
  $A tap --label "Send Reply" --udid $U >/dev/null 2>&1 || $A tap --label Send --udid $U >/dev/null; sleep 1.5
  $A tap --label close --udid $U >/dev/null 2>&1; sleep 1.2; }
reply "Ill merge ok" "Do it after the release"
reply "How about the cloud" "Still going"
xcrun simctl io $U screenshot /tmp/ctxprobe.png >/dev/null 2>&1
xcrun simctl spawn $U log show --last 2m --predicate "eventMessage CONTAINS \"appendContext\"" --style compact 2>/dev/null | grep -v "log run" | tail -5
