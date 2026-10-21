#!/bin/bash
# The Mac side of verify/e2e-live.md: a real cmux-tui daemon, acpmux with the
# credit-free agent (e2e_agent.py), and cmux-mobile-host, all user-local under $E.
#
# usage (on the Mac):  e2e-mac.sh start | stop | hostd-stop | hostd-start | status
# env: E (default ~/cmux-next-ios-e2e/e2e/live), BIN (cmux-tui + acpmux),
#      HOSTD (cmux-mobile-host), SRC (cmux-tui source, for fake_agent.py),
#      CMUX_MOBILE_TEAM_ID, CMUX_MOBILE_OWNER_USER_ID; the refresh token is read from
#      $E/secrets/refresh (0600, written over ssh stdin, never printed).
set -u
E=${E:-$HOME/cmux-next-ios-e2e/e2e/live}
BIN=${BIN:-$HOME/cmux-next-ios-e2e/demo-build/target-tui/release}
HOSTD=${HOSTD:-$HOME/cmux-next-ios-e2e/e2e/target/release/cmux-mobile-host}
SRC=${SRC:-$HOME/cmux-next-ios-e2e/e2e/src/cmux-tui}
AGENT=${AGENT:-$HOME/cmux-next-ios-e2e/e2e/e2e_agent.py}
SOCK=$E/sock/cmuxMobile.sock
PORT=47993

tui() { HOME=$E/home ACPMUX_HOME=$E/acpmux CMUX_TUI_STATE_DIR=$E/tui-state "$BIN/cmux-tui" "$@"; }
rpc() { python3 -I -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall((sys.argv[2] + "\n").encode())
f = s.makefile()
for line in f:
    m = json.loads(line)
    if "event" not in m:
        print(json.dumps(m)); break
' "$SOCK" "$1"; }

start_hostd() {
  CMUX_MOBILE_BASE_URL=https://cmux-mobile-api-dev.debussy.workers.dev \
  CMUX_MOBILE_TEAM_ID=$CMUX_MOBILE_TEAM_ID CMUX_MOBILE_OWNER_USER_ID=$CMUX_MOBILE_OWNER_USER_ID \
  CMUX_MOBILE_REFRESH_TOKEN_FILE=$E/secrets/refresh CMUX_MOBILE_STATE_DIR=$E/hostd-state \
  CMUX_MOBILE_DEVICE_NAME="mobile e2e mini 2" \
  CMUX_MOBILE_TUI_SOCKET=$SOCK CMUX_MOBILE_TUI_SOCKET_DIR=$E/sock CMUX_MOBILE_TUI_SESSION=mobile \
  CMUX_MOBILE_FILE_ROOTS=$E/work CMUX_MOBILE_ACPMUX_URL=ws://127.0.0.1:$PORT/ CMUX_MOBILE_ACPMUX_TOKEN="$(cat "$E/secrets/acpmux")" \
  CMUX_MOBILE_EXCLUDE_CGNAT=1 CMUX_MOBILE_LOG=${CMUX_MOBILE_LOG:-info} \
    nohup "$HOSTD" >> "$E/hostd.log" 2>&1 &
  echo $! > "$E/hostd.pid"
}

case ${1:-} in
start)
  mkdir -p "$E"/{sock,home,acpmux,tui-state,work,hostd-state,secrets}; chmod 700 "$E" "$E/secrets"
  [[ -s $E/secrets/refresh ]] || { echo "missing $E/secrets/refresh"; exit 1; }
  umask 077; openssl rand -hex 24 | tr -d '\n' > "$E/secrets/acpmux"; umask 022
  printf '{"harnesses":{"fake":{"argv":["python3","%s"],"env":{"FAKE_AGENT":"%s"}}},"defaultHarness":"fake","permissionPolicy":"ask","webAskingModes":{"fake":["normal","strict"]},"websocket":{"listen":"127.0.0.1:%s","token":"%s"},"webRoots":["%s"]}\n' \
    "$AGENT" "$SRC/crates/acpmux/tests/fake_agent.py" "$PORT" "$(cat "$E/secrets/acpmux")" "$E/work" > "$E/acpmux/config.json"
  chmod 600 "$E/acpmux/config.json"
  ACPMUX_HOME=$E/acpmux FAKE_AGENT=$SRC/crates/acpmux/tests/fake_agent.py nohup "$BIN/acpmux" daemon run --listen 127.0.0.1:$PORT --token "$(cat "$E/secrets/acpmux")" > "$E/acpmux.log" 2>&1 &
  echo $! > "$E/acpmux.pid"
  tui daemon start --session mobile --socket "$SOCK" > "$E/tui.log" 2>&1 &
  for _ in $(seq 1 100); do [[ -S $SOCK ]] && break; perl -e 'select(undef,undef,undef,0.1)'; done
  [[ -S $SOCK ]] || { echo "no cmux-tui socket"; cat "$E/tui.log"; exit 1; }
  # Seed: a project folder with files to preview and edit, two workspaces,
  # an agent tab bound to a fresh acpmux chat.
  mkdir -p "$E/work/demo"
  printf '# mobile e2e\n\nA real file on the Mac, previewed over the file service.\n' > "$E/work/demo/README.md"
  printf 'fn main() {\n    println!("hello from the mini");\n}\n' > "$E/work/demo/main.rs"
  rpc "{\"id\":1,\"cmd\":\"new-workspace\",\"name\":\"cmux-mobile-demo\",\"cwd\":\"$E/work/demo\"}"
  registry=$(rpc '{"id":1,"cmd":"identify"}' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["session_id"])')
  tab=$(rpc "{\"id\":2,\"cmd\":\"new-conversation-tab\",\"agent_session\":{\"host\":\"registry:$registry\"}}")
  echo "$tab"
  surface=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["data"]["surface"])' "$tab")
  rpc "{\"id\":3,\"cmd\":\"agent-session-start\",\"surface\":$surface,\"harness\":\"fake\",\"cwd\":\"$E/work/demo\"}"
  rpc "{\"id\":4,\"cmd\":\"new-workspace\",\"name\":\"notes\",\"cwd\":\"$E/work\"}"
  start_hostd
  echo started
  ;;
hostd-start) start_hostd; echo hostd started ;;
hostd-stop) kill "$(cat "$E/hostd.pid")" 2>/dev/null; echo hostd stopped ;;
status) for p in acpmux hostd; do echo "$p $(kill -0 "$(cat "$E/$p.pid" 2>/dev/null)" 2>/dev/null && echo up || echo down)"; done; ls "$SOCK" ;;
stop)
  for p in hostd acpmux; do kill "$(cat "$E/$p.pid" 2>/dev/null)" 2>/dev/null; done
  tui daemon stop --session mobile --socket "$SOCK" --force --end-terminals > /dev/null 2>&1
  rm -rf "$E/secrets"
  echo stopped
  ;;
*) sed -n 2,9p "$0"; exit 2 ;;
esac
