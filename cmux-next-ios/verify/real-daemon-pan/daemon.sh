#!/bin/bash
# The real desktop daemon for RealDaemonPanUITests, on the simulator's host Mac.
#
#   daemon.sh start DIR   the newest cmux NEXT NIGHTLY's own cmux-tui (from its DMG, the
#                         appcast's enclosure), `daemon start` on DIR/s.sock with HOME,
#                         XDG and TMPDIR inside DIR; DIR/ready holds the version once
#                         the socket answers. Progress and errors go to DIR/daemon.log.
#   daemon.sh stop DIR    stops that daemon (its pid file) and deletes DIR.
#
# The UI test starts it from the simulator (posix_spawn): the step script has no
# real-daemon mode and cannot gain one in a PR.
set -u
cmd="$1"
dir="$2"
case "$dir" in /tmp/cmux-rdp-*) ;; *) echo "daemon.sh: DIR must be /tmp/cmux-rdp-*" >&2; exit 2 ;; esac
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

if [[ "$cmd" == stop ]]; then
  if [[ -s "$dir/daemon.pid" ]]; then
    pid="$(cat "$dir/daemon.pid")"
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null
  fi
  [[ -n "$(cat "$dir/mount" 2>/dev/null)" ]] && hdiutil detach -force "$(cat "$dir/mount")" >/dev/null 2>&1
  rm -rf "$dir"
  exit 0
fi

mkdir -p "$dir/home" "$dir/xdg/config" "$dir/xdg/data" "$dir/xdg/state" "$dir/xdg/cache" "$dir/tmp"
: >"$dir/home/.zshrc"
exec >>"$dir/daemon.log" 2>&1
echo "start $(date -u +%FT%TZ)"
feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
url="$(curl -fsSL --max-time 60 "$feed" | grep -oE 'url="[^"]+\.dmg"' | head -1 | sed 's/^url="//; s/"$//')"
[[ -n "$url" ]] || { echo "error: no DMG in $feed"; exit 1; }
echo "dmg $url"
curl -fsSL --max-time 600 -o "$dir/n.dmg" "$url" || { echo "error: download failed"; exit 1; }
mnt="$dir/mnt"
mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dir/n.dmg" >/dev/null || { echo "error: attach failed"; exit 1; }
echo "$mnt" >"$dir/mount"
app="$(ls -d "$mnt"/*.app | head -1)"
ditto "$app" "$dir/app.app" || { echo "error: copy failed"; exit 1; }
hdiutil detach -force "$mnt" >/dev/null 2>&1 && : >"$dir/mount"
rm -f "$dir/n.dmg"
tui="$dir/app.app/Contents/Resources/bin/cmux-tui"
[[ -x "$tui" ]] || { echo "error: no cmux-tui in the app"; exit 1; }
version="$(cat "$dir/app.app/Contents/Resources/bin/cmux-tui.version" 2>/dev/null | tr '\n' ' ')"
echo "cmux-tui $version"
HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg/config" XDG_DATA_HOME="$dir/xdg/data" XDG_STATE_HOME="$dir/xdg/state" \
  XDG_CACHE_HOME="$dir/xdg/cache" TMPDIR="$dir/tmp/" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 \
  nohup "$tui" daemon start --session rdp --socket "$dir/s.sock" >>"$dir/daemon.log" 2>&1 </dev/null &
echo $! >"$dir/daemon.pid"
for _ in $(seq 1 300); do
  if [[ -S "$dir/s.sock" ]]; then
    echo "${version:-unknown} $url" >"$dir/ready"
    echo "ready"
    exit 0
  fi
  kill -0 "$(cat "$dir/daemon.pid")" 2>/dev/null || { echo "error: the daemon exited"; exit 1; }
  sleep 0.1
done
echo "error: no socket in 30 s"
exit 1
