#!/bin/bash
# The Mac side of verify/browser-stream.md: a real cmux-next DEV build (fleet
# tagged, with its bundled cmux-mobile-host and remote browser host) in the Mac's GUI
# session, signed in with the DEBUG dev credential, iPhone connections on, a
# clock page, and a workspace with a browser tab on it. User-local under $E.
#
# usage (on the Mac): browser-mac.sh start APP | seed | status | stop
# The credential file $E/cfg/auth.env (0600, CMUX_UITEST_STACK_EMAIL and
# _PASSWORD) arrives over ssh stdin and is never printed.
set -u
E=${E:-$HOME/cmux-next-ios-e2e/browser}
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

# The app's daemon socket, from its hostd's environment.
socket() {
  local pid; pid=$(pgrep -f "$E/app/.*/Contents/Resources/bin/cmux-mobile-host" | head -1)
  [[ -n $pid ]] || return 1
  ps eww -p "$pid" | tr ' ' '\n' | sed -n 's/^CMUX_MOBILE_TUI_SOCKET=//p' | head -1
}

case ${1:-} in
start)
  app=$2
  mkdir -p "$E/cfg" "$E/page"; chmod 700 "$E/cfg"
  [[ -s $E/cfg/auth.env ]] || { echo "missing $E/cfg/auth.env"; exit 1; }
  printf '{"mobile":{"allowIPhoneConnections":true}}\n' > "$CFG"
  (cd "$E/page" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 > "$E/page.log" 2>&1 & echo $! > "$E/page.pid")
  open -n -a "$app" --env CMUX_NEXT_CONFIG_FILE="$CFG" --env CMUX_AUTH_CREDENTIALS_FILE="$E/cfg/auth.env"
  echo started
  ;;
seed)
  sock=$(socket) || { echo "no hostd yet"; exit 1; }
  rpc "$sock" "{\"id\":1,\"cmd\":\"new-workspace\",\"name\":\"browser-demo\",\"cwd\":\"$E/page\"}"
  rpc "$sock" "{\"id\":2,\"cmd\":\"new-browser-tab\",\"url\":\"http://127.0.0.1:$PORT/clock.html\"}"
  ;;
status)
  pgrep -fl "$E/app/" | sed 's/--env [^ ]*//g' | cut -c1-160
  echo "socket: $(socket)"
  ;;
stop)
  pkill -f "$E/app/.*/Contents/MacOS/" ; kill "$(cat "$E/page.pid" 2>/dev/null)" 2>/dev/null
  rm -f "$E/cfg/auth.env"
  echo stopped
  ;;
*) sed -n 2,9p "$0"; exit 2 ;;
esac
