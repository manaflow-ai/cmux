"""Samples a Mac terminal's PTY grid and its sizing participants from the cmux-tui daemon.

Runs on the rig Mac. One control connection that never attaches and never reports a size,
so it is not a sizing participant itself. Every --interval seconds it prints one JSON line:

  {"t": <unix time>, "cols": .., "rows": .., "participants": [[kind, cols, rows], ..]}

`cols`/`rows` are the PTY grid (`vt-state`): what the Mac's pane shows. Used by
verify/e2e/size_release.py (cmux-next-ios/verify/size-release-20261021.md).

  python3 size_probe.py --socket <daemon socket> (--surface N | --list) [--policy smallest]
"""
import argparse
import json
import socket
import sys
import time


class Daemon:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b""
        self.next = 0

    def request(self, cmd, **params):
        self.next += 1
        rid = f"probe-{self.next}"
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 16)
                if not chunk:
                    raise SystemExit("daemon closed the probe connection")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            reply = json.loads(line)
            if reply.get("id") == rid:
                if reply.get("ok") is False:
                    raise RuntimeError(f"{cmd}: {reply.get('error')}")
                return reply.get("data", {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--surface", type=int)
    ap.add_argument("--list", action="store_true", help="print the terminals and exit")
    ap.add_argument("--policy", help="set this size policy on the terminal first (e.g. smallest)")
    ap.add_argument("--interval", type=float, default=0.2)
    ap.add_argument("--mac-view", help="COLSxROWS: also hold a Mac view of the terminal at this size "
                    "(a hidden rig app draws no window, so this plays the Mac pane)")
    a = ap.parse_args()
    d = Daemon(a.socket)
    if a.list:
        print(json.dumps(d.request("list-terminals"), indent=1))
        return
    mac_view = None
    if a.mac_view:
        cols, rows = (int(x) for x in a.mac_view.lower().split("x"))
        mac_view = Daemon(a.socket)
        mac_view.request("set-client-info", name="rig Mac pane", kind="mac", device_kind="mac")
        mac_view.request("attach-surface", surface=a.surface, cols=cols, rows=rows)
    if a.policy:
        d.request("set-size-policy", surface=a.surface, policy={"mode": a.policy})
    last = None
    while True:
        if mac_view is not None:
            # Drain the Mac view's stream so the daemon never blocks on it.
            mac_view.sock.setblocking(False)
            try:
                while mac_view.sock.recv(1 << 20):
                    pass
            except BlockingIOError:
                pass
            mac_view.sock.setblocking(True)
        vt = d.request("vt-state", surface=a.surface)
        state = d.request("get-size-state", surface=a.surface).get("state") or {}
        parts = [[p.get("device_kind"), (p.get("viewport") or {}).get("cols"), (p.get("viewport") or {}).get("rows"),
                  p.get("counts")] for p in state.get("participants", [])]
        sample = {"cols": vt.get("cols"), "rows": vt.get("rows"), "participants": parts}
        # Every sample, so a bound can be read from the gaps; changes are marked.
        print(json.dumps({"t": round(time.time(), 3), **sample, "changed": sample != last}), flush=True)
        last = sample
        time.sleep(a.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
