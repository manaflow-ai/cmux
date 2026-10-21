#!/usr/bin/env python3
"""mac-app-relay: the cmux app control socket of a Chief host with no app.

The Cloud Chief VM runs no cmux app. This relay listens on a Unix socket on
the VM and forwards bounded diagnostics to the user's Mac app through the Mac
gate (`mac --stdin -- …`, lawbook0:7420 over Tailscale), then writes the app's
one-line answer back. Every app action is denied until the Mac can verify an
unforgeable Chief capability and owned object ids. The host names the socket
with `CMUX_CHIEF_APP_SOCKET` and gives it to turns as `CMUX_SOCKET_PATH`.

The app protocol is one JSON request line and one JSON answer line, so each
line is one gate call (about 0.4 s). Streams (`cmux events`) do not work
through it. When the gate or the app does not answer, the answer is an app
error (`app.unreachable`) that says why, so `cmux mcp tools` and the host's
log name the cause.

usage:
  mac-app-relay.py --listen PATH [--mac-socket PATH] [--mac CMD] [--timeout S]

  --listen      the Unix socket to serve (a stale file is replaced)
  --socket-mode socket permissions, 0600 or 0660 (default 0600)
  --mac-socket  the app control socket on the Mac (default /tmp/cmux-nightly.sock,
                the NIGHTLY app; `cmux --json identify` there prints it)
  --mac         the Mac gate client (default `mac`, tools/cloud-chief/vm/mac in hq)
  --timeout     seconds one request may take on the Mac (default 30)

Python 3.9 stdlib only.
"""
import argparse
import json
import os
import shlex
import socket
import socketserver
import subprocess
import sys

# Runs on the Mac (python3 from the gate's login shell): one request line to
# the app socket, its one answer line back.
MAC_SIDE = r"""
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(float(sys.argv[2]))
s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read())
b = b""
while not b.endswith(b"\n"):
    c = s.recv(1 << 16)
    if not c:
        break
    b += c
sys.stdout.buffer.write(b)
"""

MAX_LINE = 512 << 10  # the gate's --stdin limit

# This is a remote relay policy, not only a model-tool filter. Only bounded
# diagnostics cross the host boundary. App actions remain denied until the
# Mac can verify an unforgeable Cloud Chief capability and owned object ids.
READ_METHODS = frozenset((
    "system.ping", "system.identify", "system.capabilities",
))


def unreachable(request_id, message):
    """An app error answer for `request_id` that says why the app did not answer."""
    return json.dumps({
        "id": request_id,
        "ok": False,
        "error": {"code": "app.unreachable", "message": message, "retryable": True},
    }) + "\n"


def denied(request_id):
    """A stable refusal that discloses none of the rejected request."""
    return json.dumps({
        "id": request_id,
        "ok": False,
        "error": {
            "code": "app.remote_denied",
            "message": "the Cloud Chief relay does not allow this app request",
            "retryable": False,
        },
    }) + "\n"


def allowed(request):
    """Whether one decoded app request is in the Cloud Chief relay policy."""
    if not isinstance(request, dict):
        return False
    method = request.get("method")
    return method in READ_METHODS and isinstance(request.get("params", {}), dict)


class Relay:
    def __init__(self, mac, mac_socket, timeout):
        self.mac = mac
        self.mac_socket = mac_socket
        self.timeout = timeout

    def command(self, method):
        remote = "python3 -c {} {} {}".format(
            shlex.quote(MAC_SIDE), shlex.quote(self.mac_socket), self.timeout)
        reason = "cloud chief app call {}".format(method or "?")
        return self.mac + ["--stdin", "--timeout", str(self.timeout + 10), "--reason", reason, "--", remote]

    def answer(self, line):
        """The app's answer line to one request line, or an app error line."""
        try:
            request = json.loads(line)
        except ValueError:
            request = None
        request_id = request.get("id") if isinstance(request, dict) else None
        method = request.get("method") if isinstance(request, dict) else None
        if len(line) > MAX_LINE:
            return unreachable(request_id, "request over 512 KiB; the Mac gate takes no more")
        if not allowed(request):
            return denied(request_id)
        try:
            done = subprocess.run(self.command(method), input=line, capture_output=True,
                                  timeout=self.timeout + 70)
        except subprocess.TimeoutExpired:
            return unreachable(request_id, "the Mac gate gave no answer within {} s".format(self.timeout + 70))
        except OSError as e:
            return unreachable(request_id, "cannot run the Mac gate client {}: {}".format(self.mac[0], e))
        out = done.stdout.decode(errors="replace").strip()
        if done.returncode != 0 or not out.startswith("{"):
            why = done.stderr.decode(errors="replace").strip() or out or "exit {}".format(done.returncode)
            return unreachable(request_id, "the Mac app at {} did not answer through the Mac gate: {}".format(
                self.mac_socket, why.splitlines()[-1][:400]))
        return out.splitlines()[0] + "\n"


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        while True:
            line = self.rfile.readline(MAX_LINE + 2)
            if not line:
                return
            if not line.strip():
                continue
            if not line.endswith(b"\n"):
                line += b"\n"
            self.wfile.write(self.server.relay.answer(line).encode())
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(listen, relay, ready=None, socket_mode=0o600):
    """Serves `listen` until the process ends; `ready` (an Event) is set once it listens."""
    try:
        os.unlink(listen)
    except FileNotFoundError:
        pass
    old = os.umask(0o177)
    try:
        server = Server(listen, Handler)
    finally:
        os.umask(old)
    os.chmod(listen, socket_mode)
    server.relay = relay
    if ready is not None:
        ready.set()
    server.serve_forever()


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--listen", required=True)
    p.add_argument("--socket-mode", choices=("0600", "0660"), default="0600")
    p.add_argument("--mac-socket", default=os.environ.get("MAC_APP_SOCKET", "/tmp/cmux-nightly.sock"))
    p.add_argument("--mac", default=os.environ.get("MAC_GATE_CLIENT", "mac"))
    p.add_argument("--timeout", type=int, default=30)
    a = p.parse_args(argv[1:])
    serve(a.listen, Relay(shlex.split(a.mac), a.mac_socket, a.timeout), socket_mode=int(a.socket_mode, 8))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
