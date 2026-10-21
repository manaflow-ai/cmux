#!/bin/bash
# The Mac side of verify/phone-approvals.md: a real cmux-next DEV build (fleet
# tagged, with its bundled cmux-mobile-host and acpmux) in the Mac's GUI session,
# signed in with the DEBUG agent credential, iPhone connections on, and an
# acpmux home whose default harness is acpmux's credit-free fake agent
# (`ask: X` asks a permission and replies with the chosen option). User-local
# under $E.
#
# usage (on the Mac): approvals-mac.sh start APP | ask TEXT | sessions | paired | status | stop
# The credential file $E/cfg/auth.env (0600, CMUX_UITEST_STACK_EMAIL and
# _PASSWORD) arrives over ssh stdin and is never printed.
set -u
E=${E:-$HOME/cmux-next-ios-e2e/approvals-fin/live}
CFG=$E/cfg/cmux-next.json
AGENT=${AGENT:-$E/fake_agent.py}

app_path() { pgrep -fl "$E/app/.*/Contents/MacOS/" | head -1 | sed -E 's|^[0-9]+ ||; s|/Contents/MacOS/.*||'; }
acpmux() { ACPMUX_HOME=$E/acpmux "$(app_path)/Contents/Resources/bin/acpmux" "$@"; }

case ${1:-} in
start)
  app=$2
  mkdir -p "$E/cfg" "$E/acpmux" "$E/work"; chmod 700 "$E/cfg" "$E/acpmux"
  [[ -s $E/cfg/auth.env ]] || { echo "missing $E/cfg/auth.env"; exit 1; }
  [[ -s $AGENT ]] || { echo "missing $AGENT"; exit 1; }
  printf '{"mobile":{"allowIPhoneConnections":true}}\n' > "$CFG"
  printf '{"harnesses":{"fake":{"argv":["python3","%s"]}},"defaultHarness":"fake","permissionPolicy":"ask","webAskingModes":{"fake":["normal","strict"]}}\n' "$AGENT" > "$E/acpmux/config.json"
  chmod 600 "$E/acpmux/config.json"
  open -n -a "$app" --env CMUX_NEXT_CONFIG_FILE="$CFG" --env CMUX_AUTH_CREDENTIALS_FILE="$E/cfg/auth.env" \
    --env ACPMUX_HOME="$E/acpmux"
  echo started
  ;;
ask)
  shift
  (cd "$E/work" && nohup env ACPMUX_HOME="$E/acpmux" "$(app_path)/Contents/Resources/bin/acpmux" new -m fake --cwd "$E/work" --detach "$*" \
    >> "$E/asks.log" 2>&1 &)
  echo asked
  ;;
sessions) acpmux ls 2>&1 | head -20 ;;
paired)
  # The app's paired-phone list (ids, names, dates and key fingerprints only).
  find "$HOME/Library/Application Support" -path '*cmux-mobile-host*' -name 'paired*' 2>/dev/null | while read -r f; do
    echo "$f"; python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("devices", "denied"):
    for e in d.get(k, []):
        print(k, e.get("id"), e.get("name", ""), e.get("pairedAt", e.get("paired_at", "")), (e.get("identityKey") or e.get("identity_key") or "")[:16])
' "$f"
  done
  ;;
status)
  pgrep -fl "$E/app/" | sed 's/--env [^ ]*//g' | cut -c1-160
  ;;
stop)
  pkill -f "$E/app/.*/Contents/MacOS/"
  rm -f "$E/cfg/auth.env"
  echo stopped
  ;;
*) sed -n 2,11p "$0"; exit 2 ;;
esac
