#!/bin/bash
# Offline check that a remote browser host renders an http(s) page, not only
# data: and about:blank: serves URL (default: a page on a loopback http server)
# with --serve --lifeline --once, attaches the host's own --probe viewer, and
# decodes the last received frame to OUT/page.png. Exit 0 only with frames.
#
#   rb-host-http-frames.sh HOST_APP OUT [URL]
#
# HOST_APP is a cmux-remote-browser-host.app with a real CEF framework (not
# the symlink an embedded host has). Runs on a Mac with a window server
# session; the host is a background app (no Dock icon, no focus).
# Regression: hosts before feat-cnx-ios-rbfix wait for the login Keychain's
# "Chromium Safe Storage" key before reading cookies, so every http(s) load
# hangs and the probe reports "no frame within the timeout".
set -u
app="${1:?usage: rb-host-http-frames.sh HOST_APP OUT [URL]}"
out="${2:?OUT}"
url="${3:-}"
bin="$app/Contents/MacOS/cmux-remote-browser-host"
[[ -x "$bin" ]] || { echo "error: no host binary at $bin" >&2; exit 2; }
rm -rf "$out"; mkdir -p "$out/www"
cleanup() { exec 3>&- 2>/dev/null; [[ -n "${web:-}" ]] && kill "$web" 2>/dev/null; }
trap cleanup EXIT
if [[ -z "$url" ]]; then
  mkfifo "$out/web.port.fifo"
  cat > "$out/www/index.html" <<'HTML'
<!doctype html><title>rb http page</title>
<body style="margin:0;background:#1f4e7a;color:#fff;font:48px -apple-system">
<h1 style="margin:80px">served over http</h1></body>
HTML
  python3 -I -c 'import http.server,functools,sys
h=functools.partial(http.server.SimpleHTTPRequestHandler,directory=sys.argv[1])
s=http.server.ThreadingHTTPServer(("127.0.0.1",0),h)
print(s.server_address[1],flush=True); s.serve_forever()' "$out/www" > "$out/web.port.fifo" 2> "$out/web.log" &
  web=$!
  read -r port < "$out/web.port.fifo"  # blocks until the server is bound
  url="http://127.0.0.1:$port/index.html"
fi
echo "url=$url"
secret=$(openssl rand -hex 32)
mkfifo "$out/lifeline" "$out/host.stdout.fifo"
perl -e 'alarm 120; exec @ARGV' "$bin" --serve --listen 127.0.0.1:0 --lifeline --once --url "$url" \
  < "$out/lifeline" > "$out/host.stdout.fifo" 2> "$out/host.stderr" &
host=$!
exec 3> "$out/lifeline"
printf '%s\n' "$secret" >&3
# The host's first stdout line is {"listening":"ADDR"} (blocks until bound).
exec 4< "$out/host.stdout.fifo"
read -r line <&4
cat <&4 > "$out/host.stdout" &
addr=$(printf '%s' "$line" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["listening"])' 2>/dev/null)
[[ -n "$addr" ]] || { echo "error: the host never listened" >&2; tail "$out/host.stderr" >&2; exit 1; }
printf '%s\n' "$secret" | perl -e 'alarm 60; exec @ARGV' "$bin" --probe "$addr" "$out/probe" --keys 0 \
  > "$out/probe.stdout" 2> "$out/probe.stderr"
probe=$?
exec 3>&-
wait "$host" 2>/dev/null
cat "$out/probe/result.json"; echo
if [[ "$probe" != 0 ]]; then echo "FAIL: no frames for $url" >&2; exit 1; fi
if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -y -i "$out/probe/stream.h264" -update 1 "$out/page.png" && echo "png=$out/page.png"
fi
echo "PASS: frames for $url"
