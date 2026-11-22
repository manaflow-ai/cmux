#!/usr/bin/env bash
# iPhone-to-Mac Screen Sharing connect time, on the live rig (verify/screen-sharing.md): the Debug app
# on a fleet Mac's simulator connects TRIES times to a host Mac through the device hub. Prints one JSON
# line per try from each side:
#   phone  ss-connect: {"try","connected","tap_to_stats_ms","tap_to_path_ms","path","stats"}
#          (testConnectTiming in UITests/ScreenSharingLiveUITests.swift: tap on the Mac's row until the
#          stats line shows, then until it names the WebRTC path, Direct or Relay)
#   host   host-connect: {"answer_to_open_ms","path"} from the host app's own log
#          (ScreenStreamHost in CmuxVNCWebRTC, logged under com.cmuxterm.app.next/mac-screen-rd-host:
#          "viewer offered; streaming answer sent" -> "channel open", and "path: this Mac X <-> viewer Y")
#
# The iPhone viewer is WebRTC (libwebrtc ICE through VNCPeerLink), and the Mac answers it with its in-app
# WebRTC host, not `cmux rd serve`: the cmux.rd/1 link (cmux-tui/crates/cmux-rd-link) never runs on this
# path (plans/cmux-next/remote-desktop-mac-host.md section 7, MacScreenRdHost.serve).
#
# Run it where rig.sh runs (it reaches HOST over Tailscale SSH, or ssh for mini-*). The host Mac runs the
# rig's host (run-host.sh TAG, hub.py) signed in as the same test account.
#
#   CREDS=~/.secrets/cmux-dev-agent-auth.env MAC="iOS Rig Mac mini" HOSTMAC=mini-cmuxs-mac-mini-2 \
#     verify/screen-sharing/connect-timing.sh LABEL
#
# Environment: CREDS, MAC (required, as rig.sh test); HOSTMAC (ssh name of the host Mac, required);
# TAG (the host's rig tag, default issmac1); TRIES (default 5); SKIP_BUILD=1 reuses the last sync,
# xcframework, simulator and build on HOST; HOST, DIR, SIM_NAME, HUB as rig.sh.
set -euo pipefail
label=${1:?label}
: "${CREDS:?}" "${MAC:?}" "${HOSTMAC:?HOSTMAC=<ssh name of the host Mac>}"
TAG=${TAG:-issmac1}
export TRIES=${TRIES:-5}
here=$(cd "$(dirname "$0")" && pwd)
mobile=$(cd "$here/../.." && pwd)
out="$mobile/verify/evidence/screen-sharing/$label"
mkdir -p "$out"

if [[ ${SKIP_BUILD:-0} != 1 ]]; then
  "$here/rig.sh" sync
  "$here/rig.sh" seed-xcf
  "$here/rig.sh" sim
  "$here/rig.sh" build
fi

since=$(ssh "$HOSTMAC" 'date "+%Y-%m-%d %H:%M:%S"')
# The first connect waits on the Mac's Allow: answer it Always allow, so later tries connect at once.
# Bounded: 90 tries 2 s apart, ended when the test ends.
ssh "$HOSTMAC" "for i in \$(seq 90); do python3 ~/iss-rig/hub.py $TAG approve always_full 2>/dev/null | grep -q . && break; sleep 2; done" &
approver=$!
rc=0
ONLY=CmuxMobileAppUITests/ScreenSharingLiveUITests/testConnectTiming "$here/rig.sh" test "$label" || rc=$?
kill "$approver" 2>/dev/null || true

grep -h 'ss-connect:' "$out/test-$label.log" | sed 's/.*ss-connect: /phone /' || echo "phone: no ss-connect lines (see $out/test-$label.log)"

ssh "$HOSTMAC" "log show --start '$since' --style compact --info \
  --predicate 'subsystem == \"com.cmuxterm.app.next\" AND category == \"mac-screen-rd-host\"'" > "$out/host-log.txt" || true
python3 - "$out/host-log.txt" <<'PY'
import json, re, sys
from datetime import datetime
stamp = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
answer, tries = None, []
for line in open(sys.argv[1], errors="replace"):
    m = stamp.match(line)
    if not m:
        continue
    t = datetime.strptime(m.group(1)[:26], "%Y-%m-%d %H:%M:%S.%f")
    if "streaming answer sent" in line:
        answer = t
        tries.append({"answer_to_open_ms": None, "path": None})
    elif "path: this Mac" in line and tries:
        # ICE names its pair just before or just after the channel opens: it belongs to the latest try.
        tries[-1]["path"] = tries[-1]["path"] or line.split("path: ", 1)[1].strip()
    elif "channel open" in line and answer and tries:
        tries[-1]["answer_to_open_ms"] = round((t - answer).total_seconds() * 1000)
        answer = None
for n, entry in enumerate(tries, 1):
    print("host", json.dumps({"try": n, **entry}))
PY
exit "$rc"
