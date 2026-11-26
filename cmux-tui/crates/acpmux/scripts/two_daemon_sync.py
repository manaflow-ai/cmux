#!/usr/bin/env python3
"""RFD 0140: two live acpmux daemons, a pin and a draft set on one, read on the other.

Starts daemons A and B (separate ACPMUX_HOME, each a WebSocket listener with its peer token),
makes a chat on A with a fake agent, and links B to A the way a Mac links a VM (`peer_add` on B
only). Then, with timings:
  1. offline edits: pin and draft on A before the link; B's replica has them after link-up;
  2. live edits: pin off and a new draft on A after link-up; time until B's replica has them;
  3. a cleared draft on A crosses as a tombstone;
  4. the reverse direction: pin through B's mirror row of A's chat, read on A.
B's replica is read with `_acpmux/sync/pull` from an empty vector (everything B holds).

Usage: scripts/two_daemon_sync.py [--acpmux PATH] [--timeout S] [--json] [--keep]
Exit 0 when every step converged within --timeout, 1 otherwise.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


class Rpc:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(30)
        self.s.connect(path)
        self.buf = b""
        self.next = 0
        self.call("initialize", {"protocolVersion": 1, "clientInfo": {"name": "two-daemon-sync"}})

    def call(self, method, params):
        self.next += 1
        rid = self.next
        self.s.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.s.recv(1 << 20)
                if not chunk:
                    raise RuntimeError(f"{method}: daemon closed the socket")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid and "method" not in msg:
                if msg.get("error"):
                    raise RuntimeError(f"{method}: {msg['error'].get('message')}")
                return msg.get("result")


def start(root, name, port, acpmux):
    home = os.path.join(root, name)
    os.makedirs(home, mode=0o700)
    os.chmod(home, 0o700)
    fake = os.path.join(HERE, "..", "tests", "fake_agent.py")
    cfg = {"harnesses": {"fake": {"argv": [sys.executable, fake]}}, "defaultHarness": "fake"}
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump(cfg, f)
    sock = os.path.join(home, "acpmux.sock")
    env = dict(os.environ, ACPMUX_HOME=home, ACPMUX_SOCKET=sock)
    for k in ("ACPMUX_SESSION_ID", "ACPMUX_SESSION_TOKEN", "ACPMUX_SESSION_TOKEN_SOCKET", "ACPMUX_FROM", "ACPMUX_ENV"):
        env.pop(k, None)
    r, w = os.pipe()
    p = subprocess.Popen(
        [acpmux, "daemon", "run", "--listen", f"127.0.0.1:{port}", "--token", f"tok-{name}",
         "--log", "warn", "--ready-fd", str(w)],
        env=env, pass_fds=(w,), stdin=subprocess.DEVNULL,
        stdout=open(os.path.join(home, "stdout.log"), "w"), stderr=open(os.path.join(home, "stderr.log"), "w"))
    os.close(w)
    with os.fdopen(r) as ready:
        line = ready.readline()
    if not line or not json.loads(line).get("ready"):
        p.kill()
        raise RuntimeError(f"daemon {name} did not come up; see {home}/stderr.log")
    token = None
    for _ in range(100):
        tp = os.path.join(home, "run", "peer.token")
        if os.path.exists(tp):
            token = open(tp).read().strip()
            break
        time.sleep(0.05)
    return p, home, sock, token


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def replica(rpc):
    """Every key the daemon's replica holds, as {key: value}; a delete is None."""
    got = rpc.call("_acpmux/sync/pull", {"vv": None})
    out = {}
    for e in (got.get("delta") or {}).get("entries") or []:
        if isinstance(e, dict):
            k, v = e.get("key"), e.get("value")
        else:
            k, v = e[0], e[1]
            if isinstance(v, dict) and "value" in v:
                v = v["value"]
        out[k] = v
    return out


def wait_for(read, want, timeout):
    t0 = time.monotonic()
    while True:
        got = read()
        if want(got):
            return (time.monotonic() - t0) * 1000.0, got
        if time.monotonic() - t0 > timeout:
            return None, got
        time.sleep(0.01)


def main():
    os.umask(0o077)
    ap = argparse.ArgumentParser()
    ap.add_argument("--acpmux", default=shutil.which("acpmux") or "acpmux")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the daemons' homes")
    args = ap.parse_args()

    root = tempfile.mkdtemp(prefix="two-daemon-sync-")
    procs = []
    results = []
    ok = True
    try:
        pa, pb = free_port(), free_port()
        a, home_a, sock_a, tok_a = start(root, "a", pa, args.acpmux)
        procs.append(a)
        b, home_b, sock_b, _ = start(root, "b", pb, args.acpmux)
        procs.append(b)
        ra, rb = Rpc(sock_a), Rpc(sock_b)
        version = subprocess.run([args.acpmux, "--version"], capture_output=True, text=True).stdout.strip()

        made = ra.call("session/new", {"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"name": "sync-check"}}})
        sid = made["sessionId"]
        pin, draft = f"pin/{sid}", f"draft/{sid}"

        def step(name, read, want, note=""):
            nonlocal ok
            ms, got = wait_for(read, want, args.timeout)
            ok &= ms is not None
            results.append({"step": name, "ms": None if ms is None else round(ms, 1), "note": note,
                            "seen": {k: got.get(k) for k in (pin, draft)} if isinstance(got, dict) else got})

        # 1. Offline edits on A, then B links to A.
        ra.call("_acpmux/pin", {"sessionId": sid, "pinned": True})
        ra.call("_acpmux/draft_set", {"sessionId": sid, "text": "offline draft"})
        t_link = time.monotonic()
        rb.call("_acpmux/peer_add", {"name": "a", "url": f"ws://127.0.0.1:{pa}", "token": "tok-a",
                                     "peerToken": tok_a, "wait": True})
        step("offline pin+draft on A reach B at link-up", lambda: replica(rb),
             lambda r: r.get(pin) is True and r.get(draft) == "offline draft",
             f"peer_add answered in {round((time.monotonic() - t_link) * 1000)} ms")

        # 2. Live edits on A after link-up.
        ra.call("_acpmux/pin", {"sessionId": sid, "pinned": False})
        ra.call("_acpmux/draft_set", {"sessionId": sid, "text": "live draft"})
        step("live pin off + draft on A reach B", lambda: replica(rb),
             lambda r: r.get(pin) is False and r.get(draft) == "live draft")

        # 3. A cleared draft on A.
        ra.call("_acpmux/draft_set", {"sessionId": sid, "text": ""})
        step("cleared draft on A reaches B as a delete", lambda: replica(rb),
             lambda r: draft in r and r.get(draft) is None)

        # 4. B pins A's chat through its mirror row; A reads it.
        rows = rb.call("_acpmux/sessions", {}) or {}
        mirror = next((s.get("qualifiedSessionId") for s in rows.get("sessions", [])
                       if s.get("qualifiedSessionId") == f"a/{sid}"), None)
        if mirror:
            rb.call("_acpmux/pin", {"sessionId": mirror, "pinned": True})
            step("pin through B's mirror row reaches A", lambda: replica(ra), lambda r: r.get(pin) is True,
                 f"mirror id {mirror}")
            step("... and B's replica agrees", lambda: replica(rb), lambda r: r.get(pin) is True)
        else:
            ok = False
            results.append({"step": "B's mirror row of A's chat", "ms": None, "note": "no mirror row on B", "seen": rows})

        out = {"acpmux": version, "ok": ok, "steps": results, "home": root if args.keep else None}
        if args.json:
            print(json.dumps(out, indent=2))
        else:
            print(f"acpmux {version}")
            for r in results:
                mark = "ok  " if r["ms"] is not None else "FAIL"
                ms = f"{r['ms']:.1f} ms" if r["ms"] is not None else f"not in {args.timeout:.0f} s"
                print(f"{mark} {r['step']}: {ms}  {r['note']}  seen={json.dumps(r['seen'])}")
        return 0 if ok else 1
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
        if not args.keep:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
