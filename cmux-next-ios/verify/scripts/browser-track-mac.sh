#!/bin/bash
# The Mac side of verify/browser-video-track.md "Live verification", on a
# fleet Mac's GUI session (like browser-mac.sh): a DEV cmux-next build with the
# remote browser host and this branch's cmux-mobile-host, signed in with the DEBUG dev
# credential, iPhone connections on, the rig's DEBUG pairing seed for one
# simulator, the bench page, and a workspace `bench` with a browser tab on it.
#
# usage (on the Mac): browser-track-mac.sh start APP SIM_NAME [DROP_PERMILLE] | seed | status | stop
# The credential file $E/cfg/auth.env (0600) arrives over ssh stdin, never printed.
set -u
E=${E:-$HOME/cmux-next-ios-e2e/rbvideo}
PORT=${PORT:-8765}
CFG=$E/cfg/cmux-next.json

rpc() { python3 -I -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall((sys.argv[2] + "\n").encode())
for line in s.makefile():
    m = json.loads(line)
    if "event" not in m:
        print(json.dumps(m)); break
' "$1" "$2"; }

hostd() { pgrep -f "$E/app/.*/Contents/Resources/bin/cmux-mobile-host" | head -1; }
socket() {
  local pid; pid=$(hostd)
  [[ -n $pid ]] || return 1
  ps eww -p "$pid" | tr ' ' '\n' | sed -n 's/^CMUX_MOBILE_TUI_SOCKET=//p' | head -1
}

case ${1:-} in
start)
  app=$2; sim=$3; drop=${4:-0}
  mkdir -p "$E/cfg" "$E/page"; chmod 700 "$E/cfg"
  [[ -s $E/cfg/auth.env ]] || { echo "missing $E/cfg/auth.env"; exit 1; }
  printf '{"mobile":{"allowIPhoneConnections":true}}\n' > "$CFG"
  printf '{"devices":[{"name":"%s"}]}\n' "$sim" > "$E/cfg/seed.json"; chmod 600 "$E/cfg/seed.json"
  if ! pgrep -f "http.server $PORT" >/dev/null; then
    (cd "$E/page" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 > "$E/page.log" 2>&1 & echo $! > "$E/page.pid")
  fi
  open -n -a "$app" --env CMUX_NEXT_CONFIG_FILE="$CFG" --env CMUX_AUTH_CREDENTIALS_FILE="$E/cfg/auth.env" \
    --env CMUX_NEXT_IPHONE_PAIRING_SEED="$E/cfg/seed.json" --env CMUX_MOBILE_VIDEO_DROP_PERMILLE="$drop"
  for _ in $(seq 1 120); do [[ -n $(hostd) ]] && break; sleep 1; done
  echo "hostd $(hostd) env: $(ps eww -p "$(hostd)" | tr ' ' '\n' | grep -E '^CMUX_MOBILE_VIDEO' | tr '\n' ' ')"
  ;;
seed)
  sock=$(socket) || { echo "no hostd yet"; exit 1; }
  rpc "$sock" "{\"id\":1,\"cmd\":\"new-workspace\",\"name\":\"bench\",\"cwd\":\"$E/page\"}"
  rpc "$sock" "{\"id\":2,\"cmd\":\"new-browser-tab\",\"url\":\"http://127.0.0.1:$PORT/bench.html?scroll=6\"}"
  ;;
status)
  echo "hostd $(hostd); socket $(socket)"
  grep -E "registered|device" "$HOME/Library/Application Support/"*"/cmux-mobile-host/cmux-mobile-host.log" 2>/dev/null | tail -2
  ;;
stop)
  pkill -f "$E/app/.*/Contents/MacOS/" ; kill "$(cat "$E/page.pid" 2>/dev/null)" 2>/dev/null
  rm -f "$E/cfg/auth.env"
  echo stopped
  ;;
*) sed -n 2,9p "$0"; exit 2 ;;
esac
