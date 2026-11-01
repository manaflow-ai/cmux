#!/usr/bin/env python3
"""First-turn cost guard for the Chief (scripts/ci/chief-first-turn-cost.sh).

Two commands:

  first_turn_cost.py proxy DIR
      A Messages API stand-in on 127.0.0.1 (a free port, written to
      DIR/port and then as one line on stdout, the line the guard waits
      for). It records every request (DIR/NNNN.req.json: one JSON head
      line with the method, path and headers, credentials redacted, then the
      body) and answers every POST /v1/messages with one canned reply
      ("noted", end_turn; streamed when the request streams). No model runs,
      so the turn costs nothing and no credential reaches the worker.

  first_turn_cost.py count DIR --url URL [--limit N]
      Counts the input tokens of every recorded /v1/messages request with
      URL/v1/messages/count_tokens (the team subrouter: it signs the request
      itself), with the request's own anthropic-beta header, so deferred
      tools (ToolSearch) count as the API counts them. Fails (exit 1) when a
      request is over the limit (default 50,000), when no request was
      recorded, or when the largest request names no cmux MCP tool
      (mcp__cmux__): then the cmux MCP server never reached the turn and the
      guard would measure nothing. When count_tokens fails (the team subrouter
      answers 502: Claude subscriptions do not serve it and Bedrock has none),
      the request's tokens are estimated from its bytes (ESTIMATE_RULE) with a
      WARNING line, and the limit still applies; it never passes silently.
"""
import argparse
import glob
import hashlib
import http.server
import json
import math
import os
import socketserver
import sys
import threading
import urllib.error
import urllib.request

REDACT = {"authorization", "x-api-key", "cookie", "proxy-authorization"}
CANNED = "noted"
NOT_FOUND = json.dumps({"type": "error", "error": {"type": "not_found_error", "message": "first-turn guard stand-in"}}).encode()
COUNT_FIELDS = ("model", "messages", "system", "tools", "tool_choice", "thinking", "mcp_servers")


def proxy(out):
    os.makedirs(out, exist_ok=True)
    lock = threading.Lock()
    seq = [0]

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def record(self):
            n = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(n) if n else b""
            with lock:
                seq[0] += 1
                k = seq[0]
            head = {"method": self.command, "path": self.path,
                    "headers": {h: ("<redacted>" if h.lower() in REDACT else v) for h, v in self.headers.items()}}
            with open(os.path.join(out, f"{k:04d}.req.json"), "wb") as f:
                f.write(json.dumps(head).encode() + b"\n" + body)
            return k, body

        def send(self, status, ctype, data):
            self.send_response(status)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def do_HEAD(self):
            self.send(200, "text/plain", b"")

        def do_GET(self):
            self.record()
            self.send(404, "application/json", NOT_FOUND)

        def do_POST(self):
            k, body = self.record()
            path = self.path.split("?", 1)[0]
            if path.endswith("/v1/messages/count_tokens"):
                return self.send(200, "application/json", b'{"input_tokens": 1}')
            if not path.endswith("/v1/messages"):
                return self.send(404, "application/json", NOT_FOUND)
            try:
                req = json.loads(body)
            except ValueError:
                req = {}
            model = req.get("model") or "claude"
            usage = {"input_tokens": 1, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
            mid = f"msg_firstturn_{k:04d}"
            if not req.get("stream"):
                return self.send(200, "application/json", json.dumps({
                    "id": mid, "type": "message", "role": "assistant", "model": model,
                    "content": [{"type": "text", "text": CANNED}], "stop_reason": "end_turn",
                    "stop_sequence": None, "usage": usage}).encode())
            events = [
                ("message_start", {"type": "message_start", "message": {
                    "id": mid, "type": "message", "role": "assistant", "model": model, "content": [],
                    "stop_reason": None, "stop_sequence": None, "usage": usage}}),
                ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": CANNED}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                   "usage": {"output_tokens": 1}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            data = b"".join(f"event: {e}\ndata: {json.dumps(d)}\n\n".encode() for e, d in events)
            self.send(200, "text/event-stream", data)

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True

        def server_bind(self):
            # HTTPServer.server_bind also names the bound address (socket.getfqdn), a reverse
            # DNS lookup of 127.0.0.1: 35 s on aws-m4pro-4 and -8, so the guard gave up before
            # the port was written (cx-rkzfny). The stand-in needs no name.
            socketserver.TCPServer.server_bind(self)
            self.server_name, self.server_port = self.server_address[:2]

    srv = Server(("127.0.0.1", 0), Handler)
    tmp = os.path.join(out, "port.tmp")
    with open(tmp, "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp, os.path.join(out, "port"))
    # The guard waits for this line or for this process to end (no fixed wait).
    print(srv.server_address[1], flush=True)
    srv.serve_forever()


def requests(out):
    seen = set()
    for p in sorted(glob.glob(os.path.join(out, "*.req.json"))):
        raw = open(p, "rb").read()
        head, _, body = raw.partition(b"\n")
        head = json.loads(head)
        if head["method"] != "POST" or not head["path"].split("?", 1)[0].endswith("/v1/messages"):
            continue
        digest = hashlib.sha256(body).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        yield os.path.basename(p), head, body


# The fallback when count_tokens fails (the team subrouter answers 502: Claude
# subscriptions do not serve count_tokens and Bedrock has none): the request's
# JSON bytes without the deferred tools (the API does not count those either)
# over 3.2 bytes per token. Real Claude requests run about 3.5-4 bytes per token,
# so this overstates the tokens: it fails early, never passes a large request.
ESTIMATE_BYTES_PER_TOKEN = 3.2
ESTIMATE_RULE = "ceil(bytes of the request JSON without defer_loading tools / 3.2)"


def referenced(messages):
    """Tool names a ToolSearch result loaded (tool_reference blocks): counted in full."""
    names = set()
    stack = [messages]
    while stack:
        v = stack.pop()
        if isinstance(v, dict):
            if v.get("type") == "tool_reference" and isinstance(v.get("tool_name"), str):
                names.add(v["tool_name"])
            stack.extend(v.values())
        elif isinstance(v, list):
            stack.extend(v)
    return names


def estimate(payload):
    """None when the request has tools the bytes do not hold (mcp_servers): no safe estimate."""
    if payload.get("mcp_servers"):
        return None
    p = dict(payload)
    if p.get("tools"):
        loaded = referenced(p.get("messages"))
        p["tools"] = [t for t in p["tools"] if not t.get("defer_loading") or t.get("name") in loaded]
    return math.ceil(len(json.dumps(p).encode()) / ESTIMATE_BYTES_PER_TOKEN)


def count(out, url, limit, timeout=120):
    rows = []
    for name, head, body in requests(out):
        req = json.loads(body)
        payload = {k: req[k] for k in COUNT_FIELDS if k in req}
        hdrs = {k.lower(): v for k, v in head["headers"].items()}
        send = {"content-type": "application/json", "x-api-key": "placeholder-the-router-signs",
                "anthropic-version": hdrs.get("anthropic-version", "2023-06-01")}
        if hdrs.get("anthropic-beta"):
            send["anthropic-beta"] = hdrs["anthropic-beta"]
        r = urllib.request.Request(url.rstrip("/") + "/v1/messages/count_tokens", data=json.dumps(payload).encode(),
                                   headers=send, method="POST")
        source = "count_tokens"
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                tokens = json.load(resp)["input_tokens"]
        except urllib.error.HTTPError as e:
            tokens = estimate(payload)
            source = "estimate"
            try:
                detail = e.read()[:200].decode("utf-8", "replace")
            except OSError as read_error:
                detail = repr(read_error)
            why = f"count_tokens {e.code}: {detail}"
            print(f"FIRST-TURN-COST WARNING {name}: {why}; using the local estimate {ESTIMATE_RULE} = {tokens}",
                  file=sys.stderr)
        except (urllib.error.URLError, TimeoutError, OSError, KeyError, ValueError) as e:
            tokens = estimate(payload)
            source = "estimate"
            print(f"FIRST-TURN-COST WARNING {name}: count_tokens failed ({e!r}); using the local estimate "
                  f"{ESTIMATE_RULE} = {tokens}", file=sys.stderr)
        if tokens is None:
            print(f"FIRST-TURN-COST FAIL: {name}: count_tokens failed and the request names mcp_servers, whose tools "
                  "its bytes do not hold: no safe estimate", file=sys.stderr)
            return 1
        names = [t.get("name", "") for t in req.get("tools") or []]
        rows.append({"request": name, "model": req.get("model"), "bytes": len(body), "tools": len(names),
                     "deferred_tools": sum(1 for t in req.get("tools") or [] if t.get("defer_loading")),
                     "cmux_mcp_tools": sum(1 for n in names if n.startswith("mcp__cmux__")),
                     "cmux_mcp": b"mcp__cmux__" in body, "tokens": tokens, "source": source})
        print("FIRST-TURN-COST-REQUEST " + json.dumps(rows[-1]))
    if not rows:
        print("FIRST-TURN-COST no /v1/messages request was recorded: the turn never reached the stand-in", file=sys.stderr)
        return 1
    top = max(rows, key=lambda r: r["tokens"])
    verdict = {"limit": limit, "max_tokens": top["tokens"], "max_request": top["request"], "requests": len(rows),
               "cmux_mcp_seen": top["cmux_mcp"]}
    print("FIRST-TURN-COST " + json.dumps(verdict))
    if not verdict["cmux_mcp_seen"]:
        print(f"FIRST-TURN-COST the largest request {top['request']} names no cmux MCP tool (mcp__cmux__): the "
              "cmux MCP server did not reach the turn, so this run measures nothing", file=sys.stderr)
        return 1
    if top["tokens"] > limit:
        print(f"FIRST-TURN-COST FAIL: {top['request']} is {top['tokens']} input tokens, over the limit {limit}. A new "
              "Chief's first turn must stay small: keep the cmux MCP tools behind ToolSearch "
              "(session_dir::TURN_SETTINGS_ENV) and the always-loaded tools and prompt short.", file=sys.stderr)
        return 1
    print(f"FIRST-TURN-COST PASS: {top['tokens']} <= {limit}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("proxy")
    p.add_argument("dir")
    c = sub.add_parser("count")
    c.add_argument("dir")
    c.add_argument("--url", required=True)
    c.add_argument("--limit", type=int, default=50000)
    c.add_argument("--timeout", type=float, default=120, help="seconds per count_tokens call (short when the route is down)")
    a = ap.parse_args()
    if a.cmd == "proxy":
        proxy(a.dir)
    else:
        sys.exit(count(a.dir, a.url, a.limit, a.timeout))


if __name__ == "__main__":
    main()
