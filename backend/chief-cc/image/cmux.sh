#!/usr/bin/env bash
# cmux on a Cloud Chief turn machine: the person's Mac cmux CLI (cmux NEXT app and its daemon), run through the
# Mac gate (`mac`, the Chief's token; every call is in the Mac's audit log). Same arguments as on the Mac.
set -euo pipefail
mac health >/dev/null || exit 125
# shellcheck disable=SC2016 # expanded on the Mac
exec mac --timeout "${CMUX_MAC_TIMEOUT:-120}" -- /bin/zsh -c '
H=$HOME/.cmux/chief/default/state
export CMUX_SOCKET_PATH=$H/app.sock CMUX_TUI_SOCKET=$H/app-daemon.sock CMUX_APP_DAEMON_SOCKET=$H/app-daemon.sock
for b in "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux" "/Applications/cmux.app/Contents/Resources/bin/cmux"; do
  [[ -x $b ]] && exec "$b" "$@"
done
echo "cmux: no cmux NEXT app on the Mac" >&2; exit 127' cmux "$@"
