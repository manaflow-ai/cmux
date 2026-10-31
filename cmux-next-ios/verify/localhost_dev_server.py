#!/usr/bin/env python3
"""A dev server on the rig Mac's loopback only (localhost_forward_live.py).

    python3 localhost_dev_server.py PORT NONCE

`/` is a page naming NONCE whose script fetches `/live.json` from the same origin and
writes "fetched NONCE" into the page: a phone that renders both got the page and its own
request over the link. Listens on 127.0.0.1 only, never another interface.
"""
import http.server
import json
import socketserver
import sys

PORT, NONCE = int(sys.argv[1]), sys.argv[2]
PAGE = f"""<!doctype html><meta name=viewport content="width=device-width">
<title>Mac dev server</title>
<body style="font:28px -apple-system;padding:24px">
<h1>Served on the Mac's localhost</h1>
<p>{NONCE}</p>
<p id=live>waiting for the page's own request…</p>
<script>
fetch('/live.json').then(r => r.json()).then(j => {{ live.textContent = 'fetched ' + j.nonce; }})
  .catch(e => {{ live.textContent = 'fetch failed: ' + e; }});
</script>""".encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body, kind = (json.dumps({"nonce": NONCE}).encode(), "application/json") if self.path == "/live.json" else (PAGE, "text/html")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"{self.client_address[0]} {fmt % args}\n")


socketserver.ThreadingTCPServer.daemon_threads = True
socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler) as server:
    server.serve_forever()
