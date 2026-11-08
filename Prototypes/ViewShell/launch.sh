#!/usr/bin/env bash
# Opens cmux NEXT's UI in real native windows (README.md): builds the view shell once (seconds; it
# links nothing of the app, so it rebuilds only when Prototypes/ViewShell changes), starts the
# gallery dev server when none answers (hot reload: a saved web file shows in every open window),
# then opens one window per --size. Every other flag is a mock app axis or a shell flag
# (`cmux-view-shell --help`).
#
#   Prototypes/ViewShell/launch.sh --size 1512x982 --size 1280x800 --size 900x700 --script streaming
#   cmux preview open --fixture app.window/new-tab --density compact
set -euo pipefail

package="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$package/../.." && pwd)"
port="${CMUX_GALLERY_DEV_PORT:-4210}"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "view shell: runs on a Mac" >&2
  exit 1
fi

uses_dist=0
for arg in "$@"; do [[ "$arg" == --dist || "$arg" == --url ]] && uses_dist=1; done

server_pid=""
# Stops only the server this script started: bun and the children it spawned (found by parent PID).
cleanup() {
  [[ -n "$server_pid" ]] || return 0
  local children
  children="$(pgrep -P "$server_pid" 2>/dev/null || true)"
  kill "$server_pid" $children 2>/dev/null || true
}
trap cleanup EXIT

if (( ! uses_dist )) && ! curl -fsS -o /dev/null "http://127.0.0.1:$port/gallery/mock-app.html"; then
  echo "view shell: starting the gallery dev server on :$port (hot reload)" >&2
  (cd "$root/webviews" && exec bun run gallery:dev) >"${TMPDIR:-/tmp}/cmux-view-shell-gallery.log" 2>&1 &
  server_pid=$!
  ready=0
  for _ in $(seq 1 120); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/gallery/mock-app.html"; then ready=1; break; fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.5
  done
  if (( ! ready )); then
    echo "view shell: the gallery dev server did not answer on :$port (log: ${TMPDIR:-/tmp}/cmux-view-shell-gallery.log)." >&2
    echo "  Is another server on :$port from a checkout without gallery/mock-app.html? Set CMUX_GALLERY_DEV_PORT." >&2
    exit 1
  fi
fi

swift build -c release --package-path "$package" --product cmux-view-shell >&2
binary="$(swift build -c release --package-path "$package" --show-bin-path)/cmux-view-shell"
if (( uses_dist )); then
  exec "$binary" "$@"
fi
"$binary" --url "http://127.0.0.1:$port/gallery/mock-app.html" "$@"
