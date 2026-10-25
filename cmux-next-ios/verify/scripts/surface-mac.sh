#!/bin/bash
# The Mac side of verify/simulator-surface.md "Live check", on a fleet Mac's GUI
# session (like browser-track-mac.sh): a DEV cmux-next build of this branch,
# hidden, signed in with the DEBUG dev credential, iPhone connections on, the
# rig's DEBUG pairing seed for one phone simulator, a headless booted iOS
# simulator (never Simulator.app) showing the bench page in Safari, and a
# workspace `bench` whose only tab is a phone tab of that simulator.
#
# usage (on the Mac): surface-mac.sh start APP PHONE_SIM_NAME | seed | status | stop
# The credential file $E/cfg/auth.env (0600) arrives over ssh stdin, never printed.
set -u
E=${E:-$HOME/cmux-next-ios-e2e/simsurface}
PORT=${PORT:-8765}
CFG=$E/cfg/cmux-next.json
RIG_SIM=${RIG_SIM:-cmux-simsurface-rig}

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
rig_udid() { xcrun simctl list devices -j | python3 -I -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for v in d.values() for x in v if x['name']=='$RIG_SIM'), ''))"; }

case ${1:-} in
start)
  app=$2; sim=$3
  mkdir -p "$E/cfg" "$E/page"; chmod 700 "$E/cfg"
  [[ -s $E/cfg/auth.env ]] || { echo "missing $E/cfg/auth.env"; exit 1; }
  printf '{"mobile":{"allowIPhoneConnections":true}}\n' > "$CFG"
  printf '{"devices":[{"name":"%s"}]}\n' "$sim" > "$E/cfg/seed.json"; chmod 600 "$E/cfg/seed.json"
  if ! pgrep -f "http.server $PORT" >/dev/null; then
    (cd "$E/page" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 > "$E/page.log" 2>&1 & echo $! > "$E/page.pid")
  fi
  udid=$(rig_udid)
  if [[ -z $udid ]]; then
    runtime=$(xcrun simctl list runtimes -j | python3 -I -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['isAvailable'] and x['platform']=='iOS']; print(r[0]['identifier'])")
    udid=$(xcrun simctl create "$RIG_SIM" "iPhone 17" "$runtime")
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl openurl "$udid" "http://127.0.0.1:$PORT/bench.html?scroll=${SCROLL:-6}"
  echo "rig simulator $udid"
  # -g: never in front, -j: hidden; settings only through --env.
  open -g -j -n -a "$app" --env CMUX_NEXT_CONFIG_FILE="$CFG" --env CMUX_AUTH_CREDENTIALS_FILE="$E/cfg/auth.env" \
    --env CMUX_NEXT_IPHONE_PAIRING_SEED="$E/cfg/seed.json"
  for _ in $(seq 1 120); do [[ -n $(hostd) ]] && break; sleep 1; done
  echo "hostd $(hostd) env: $(ps eww -p "$(hostd)" | tr ' ' '\n' | grep -E '^CMUX_MOBILE_(SURFACE|BROWSER)_HOSTS' | tr '\n' ' ')"
  ;;
seed)
  sock=$(socket) || { echo "no hostd yet"; exit 1; }
  udid=$(rig_udid)
  ws=$(rpc "$sock" "{\"id\":1,\"cmd\":\"new-workspace\",\"name\":\"bench\",\"cwd\":\"$E/page\"}")
  echo "$ws"
  wid=$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1])["data"]; print(d.get("workspace") or d.get("id"))' "$ws")
  rpc "$sock" "{\"id\":2,\"cmd\":\"new-conversation-tab\",\"workspace\":$wid,\"page\":\"phone\",\"route\":\"sim:$udid\"}"
  ;;
status)
  echo "hostd $(hostd); socket $(socket); rig simulator $(rig_udid)"
  ;;
stop)
  pkill -f "$E/app/.*/Contents/MacOS/" ; kill "$(cat "$E/page.pid" 2>/dev/null)" 2>/dev/null
  udid=$(rig_udid); [[ -n $udid ]] && xcrun simctl shutdown "$udid" 2>/dev/null
  rm -f "$E/cfg/auth.env"
  echo stopped
  ;;
*) sed -n 2,10p "$0"; exit 2 ;;
esac
