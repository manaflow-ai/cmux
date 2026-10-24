"""The rig Mac's side of the terminal sizing policy check (verify/terminal-sizing-policy.md).

Runs ON the rig Mac. For each terminal surface it holds a Mac view (`device_kind: mac`, a
local connection: the daemon counts it as this Mac's pane, which a hidden rig app does not
draw) and prints one JSON line per surface every --interval seconds:

  {"t":.., "surface":N, "cols":.., "rows":.., "reason":.., "mode":..,
   "owners":[[kind, name, device_id]..], "participants":[[id, kind, name, device_id, cols, rows, counts]..]}

`cols`/`rows` are the PTY grid (`vt-state`): what the Mac's pane shows.

Commands, one JSON object per line on stdin (the driver on the simulator host relays them):
  {"op":"policy","mode":"mac","order":["device:<id>","mac"]}
      the Mac's Terminal Size When Shared: written to the rig's cmux-next.json the way a
      person (or Settings > Mobile) writes it; the daemon re-reads the file
  {"op":"type","surface":N,"text":"..."}   typing in the Mac pane (activity for Prefer the Active Device)
  {"op":"run","surface":N,"text":"htop"}   the same, with a return
  {"op":"mac-size","surface":N,"cols":C,"rows":R}   the Mac pane resized

  python3 sizing_probe.py --socket SOCK --config CMUX_NEXT_JSON --surface N [--surface M ..] --mac-view 120x39
  python3 sizing_probe.py --socket SOCK --config X --setup WORKDIR   (prints {"claude":N,"htop":M,"vim":K})

--setup makes three workspaces, szpol-claude (Claude Code asked for a long answer),
szpol-htop and szpol-vim (a file of numbered lines), at the Mac pane's size.
"""
import argparse
import json
import os
import select
import socket
import sys
import tempfile
import threading
import time


class Daemon:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b""
        self.next = 0
        self.lock = threading.Lock()

    def request(self, cmd, **params):
        with self.lock:
            self.next += 1
            rid = f"szp-{self.next}"
            self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
            while True:
                while b"\n" not in self.buf:
                    chunk = self.sock.recv(1 << 20)
                    if not chunk:
                        raise SystemExit("daemon closed the probe connection")
                    self.buf += chunk
                line, self.buf = self.buf.split(b"\n", 1)
                try:
                    reply = json.loads(line)
                except ValueError:
                    continue
                if reply.get("id") == rid:
                    if reply.get("ok") is False:
                        raise RuntimeError(f"{cmd}: {reply.get('error')}")
                    return reply.get("data", {})

    def drain(self):
        """Reads whatever the attach stream sent, so the daemon never blocks on this view."""
        with self.lock:
            self.sock.setblocking(False)
            try:
                while True:
                    chunk = self.sock.recv(1 << 20)
                    if not chunk:
                        break
            except (BlockingIOError, InterruptedError):
                pass
            finally:
                self.sock.setblocking(True)


def write_policy(config, mode, order):
    try:
        cfg = json.load(open(config))
    except (OSError, ValueError):
        cfg = {}
    mobile = cfg.setdefault("mobile", {})
    mobile["terminalSizing"] = mode
    if order is not None:
        mobile["terminalSizingOrder"] = order
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(config))
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, config)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--surface", type=int, action="append")
    ap.add_argument("--setup", help="make the three program workspaces with this work folder and exit")
    ap.add_argument("--mac-view", default="120x39")
    ap.add_argument("--interval", type=float, default=0.25)
    a = ap.parse_args()
    d = Daemon(a.socket)
    cols, rows = (int(x) for x in a.mac_view.lower().split("x"))
    if a.setup:
        os.makedirs(a.setup, exist_ok=True)
        with open(os.path.join(a.setup, "szpol.txt"), "w") as f:
            for i in range(1, 80):
                f.write(f"szpol-vim-line {i:02d}: the quick brown fox jumps over the lazy dog, then keeps going to the right edge of a wide grid\n")
        made = {}
        for program, cmd in (("claude", f"cd {a.setup} && claude"), ("htop", "/opt/homebrew/bin/htop"),
                             ("vim", f"vim {a.setup}/szpol.txt")):
            surface = d.request("new-workspace", name=f"szpol-{program}", cols=cols, rows=rows)["surface"]
            d.request("send", surface=surface, text=cmd + "\r")
            made[program] = surface
        print(json.dumps(made), flush=True)
        return
    views = {}
    for surface in a.surface:
        v = Daemon(a.socket)
        v.request("set-client-info", name="rig Mac pane", kind="mac", device_kind="mac",
                  device_name="Rig Mac pane", capabilities=["shared-sizing-v1"])
        v.request("attach-surface", surface=surface, cols=cols, rows=rows)
        views[surface] = v

    def emit(obj):
        print(json.dumps({"t": round(time.time(), 3), **obj}), flush=True)

    def commands():
        for line in sys.stdin:
            try:
                c = json.loads(line)
                op = c.get("op")
                if op == "policy":
                    write_policy(a.config, c["mode"], c.get("order"))
                elif op in ("type", "run"):
                    v = views[int(c["surface"])]
                    text = c["text"] + ("\r" if op == "run" else "")
                    v.request("send", surface=int(c["surface"]), text=text)
                elif op == "mac-size":
                    v = views[int(c["surface"])]
                    v.request("resize-surface", surface=int(c["surface"]), cols=int(c["cols"]), rows=int(c["rows"]))
                emit({"command": c, "ok": True})
            except Exception as e:  # noqa: BLE001 - reported to the driver, the probe keeps sampling
                emit({"command": line.strip(), "ok": False, "error": f"{type(e).__name__}: {e}"})

    threading.Thread(target=commands, daemon=True).start()
    while True:
        for surface, v in views.items():
            v.drain()
            vt = d.request("vt-state", surface=surface)
            state = d.request("get-size-state", surface=surface).get("state") or {}
            rows_ = {p["id"]: p for p in state.get("participants", [])}
            parts = [[p.get("id"), p.get("device_kind"), p.get("device_name"), p.get("device_id"),
                      (p.get("viewport") or {}).get("cols"), (p.get("viewport") or {}).get("rows"), p.get("counts")]
                     for p in state.get("participants", [])]
            owners = [[rows_.get(o, {}).get("device_kind"), rows_.get(o, {}).get("device_name"),
                       rows_.get(o, {}).get("device_id")] for o in state.get("owners", [])]
            emit({"surface": surface, "cols": vt.get("cols"), "rows": vt.get("rows"),
                  "reason": state.get("reason"), "mode": (state.get("policy") or {}).get("mode"),
                  "owners": owners, "participants": parts})
        select.select([], [], [], a.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
