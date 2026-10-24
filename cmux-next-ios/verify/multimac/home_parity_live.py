"""Home parity over the real link: the iPhone's Home next to the same Mac's Home.

One headless simulator runs the iOS app; one hidden rig Mac (rig.py on a mini,
started with this branch's cmux-mobile-host through CMUX_NEXT_MOBILE_HOST_BIN)
signed in to the same dev account. The script reads the Mac's Home list from
the Mac itself (its window snapshot and its own Home report through the rig
app's debug socket, never through the phone), then:

1. Home on the phone lists the Mac's conversations, no agent-chat rows.
2. Pin on the phone pins the conversation on the Mac (the Mac's grid shows it).
3. Mark as Unread on the phone marks it on the Mac; Mark as Read clears it.
4. Unpin on the phone unpins it on the Mac.

    python3 home_parity_live.py --app PATH --udid UDID --rig HOST [--out DIR] [--keep-install]

Writes DIR/results.json, DIR/run.log and DIR/shots/ (phone and Mac stills side by side).
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from journey import Fail, Journey, check  # noqa: E402
from sim import Sim  # noqa: E402

DEBUG_CALL = r'''
import glob, json, socket, sys
sock = glob.glob("/tmp/cmux-debug-cmux-mobile-e2e-*.sock")[0]
s = socket.socket(socket.AF_UNIX); s.connect(sock)
s.sendall((json.dumps({"id": "1", "method": sys.argv[1], "params": json.loads(sys.argv[2])}) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    d = s.recv(1 << 20)
    if not d: break
    buf += d
print(buf.decode())
'''


class MacRig:
    """The rig Mac, over SSH, or on this host when `host` is `local` (the simulator on the rig's mini)."""

    def __init__(self, host):
        self.host = host

    def ssh(self, command, **kw):
        argv = ["zsh", "-c", command] if self.host == "local" else ["ssh", self.host, command]
        return subprocess.run(argv, capture_output=True, text=True, timeout=60, **kw)

    def debug(self, method, params=None):
        r = self.ssh(f"python3 - {method} '{json.dumps(params or {})}'", input=DEBUG_CALL)
        return json.loads(r.stdout or "{}").get("result")

    def home_inbox(self):
        """The Mac's own Home rows (the Chief home daemon's `home-inbox`, local owner), read on the Mac."""
        page = self.debug("debug.home") or {}
        sock = (page.get("chief_owner") or {}).get("session")
        r = self.ssh(f"""python3 - <<'EOF'
import glob, json, socket
sock = glob.glob("/var/folders/*/*/T/cmux-tui-*/{sock}.sock") + glob.glob("/tmp/cmux-tui-*/{sock}.sock")
s = socket.socket(socket.AF_UNIX); s.connect(sock[0])
s.sendall(b'{{"id":"h","cmd":"home-inbox","owners":["local"]}}\\n')
buf = b""
while b"\\n" not in buf:
    buf += s.recv(1 << 20)
print(buf.split(b"\\n")[0].decode())
EOF""")
        try:
            return json.loads(r.stdout)["data"]["rows"]
        except (ValueError, KeyError, TypeError):
            return None

    def snapshot(self, local_path):
        remote = f"/tmp/home-parity-{os.path.basename(local_path)}"
        self.debug("debug.window_snapshot", {"path": remote, "kind": "main"})
        if self.host == "local":
            subprocess.run(["cp", remote, local_path], timeout=60)
        else:
            subprocess.run(["scp", "-q", f"{self.host}:{remote}", local_path], timeout=60)

    def name(self):
        return self.ssh("scutil --get ComputerName").stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--rig", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "evidence", time.strftime("%Y%m%d-%H%M%S") + "-home"))
    ap.add_argument("--keep-install", action="store_true")
    a = ap.parse_args()
    shots = os.path.join(a.out, "shots")
    os.makedirs(shots, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    mac = MacRig(a.rig)
    mac_name = mac.name()
    sim = Sim(a.udid, shots_dir=shots)
    j = Journey(sim, None, a.out, a.app, log)
    results = {"mac": {"host": a.rig, "name": mac_name}, "checks": {}}
    c = results["checks"]

    if not a.keep_install:
        j.s_fresh_install()
        j.s_sign_in()
        j.s_choose_space()
    log("signed in")

    def mac_rows():
        rows = mac.home_inbox() or []
        return [{k: r.get(k) for k in ("id", "kind", "name", "unread", "pinned", "marked_unread")} for r in rows]

    def phone_rows():
        return {e.ident: e.label for e in sim.tree() if e.ident and (e.ident.startswith("home.row.")
                or e.ident.startswith("home.pin.") or e.ident in ("home.chief", "home.chief.mac"))}

    def wait_mac(pred, timeout=20):
        deadline = time.time() + timeout
        rows = mac_rows()
        while time.time() < deadline and not pred(rows):
            time.sleep(1.0)
            rows = mac_rows()
        return pred(rows), rows

    def menu(ident, item):
        el = sim.wait(ident=ident, timeout=20)
        check(el, f"{ident} not on Home")
        x, y = el.center
        sim.long_press(x, y, 1.2)
        time.sleep(1.2)
        sim.tap_q(label=item, timeout=10)
        time.sleep(2.0)

    # Choose the rig Mac (the dev account lists other Macs too): the Workspaces filter links and focuses it.
    j.back_to_list()
    if sim.wait(ident="workspaces.filter", timeout=60):
        sim.tap_q(ident="workspaces.filter", timeout=20)
        time.sleep(1.0)
        sim.tap_q(contains=mac_name, timeout=20)
        time.sleep(3.0)
    j.tab("Home")
    row = sim.wait(ident="home.chief.mac", timeout=90)
    check(row, "the Mac's Chief never showed on Home")
    time.sleep(2.0)
    rows = mac_rows()
    log(f"mac home-inbox: {rows}")
    target = next((r["id"] for r in rows if r["kind"] == "chief"), None)
    check(target, "the Mac lists no Chief conversation")
    sim.shot("01-phone-home")
    mac.snapshot(os.path.join(shots, "01-mac-home.png"))
    p = phone_rows()
    log(f"phone rows: {p}")
    c["phone_rows"] = p
    c["mac_rows"] = rows
    c["no_agent_rows"] = bool(p) and not any("Claude" in (v or "") or "Codex" in (v or "") or "Agent ·" in (v or "") for v in p.values())

    # 2. Pin on the phone.
    menu("home.chief.mac", "Pin")
    ok, rows = wait_mac(lambda rs: any(r["id"] == target and r["pinned"] for r in rs))
    log(f"pin reached the Mac: {ok}")
    c["pin_reached_mac"] = ok
    sim.shot("02-phone-pinned")
    mac.snapshot(os.path.join(shots, "02-mac-pinned.png"))

    # 3. Mark as Unread, then Mark as Read.
    menu("home.chief.mac", "Mark as Unread")
    ok, rows = wait_mac(lambda rs: any(r["id"] == target and r["marked_unread"] for r in rs))
    log(f"mark unread reached the Mac: {ok}")
    c["mark_unread_reached_mac"] = ok
    sim.shot("03-phone-unread")
    mac.snapshot(os.path.join(shots, "03-mac-unread.png"))
    menu("home.chief.mac", "Mark as Read")
    ok, rows = wait_mac(lambda rs: any(r["id"] == target and not r["marked_unread"] for r in rs))
    c["mark_read_reached_mac"] = ok

    # 4. Unpin.
    menu("home.chief.mac", "Unpin")
    ok, rows = wait_mac(lambda rs: any(r["id"] == target and not r["pinned"] for r in rs))
    log(f"unpin reached the Mac: {ok}")
    c["unpin_reached_mac"] = ok
    sim.shot("04-phone-unpinned")
    mac.snapshot(os.path.join(shots, "04-mac-unpinned.png"))

    results["pass"] = all(c.get(k) for k in ("no_agent_rows", "pin_reached_mac", "mark_unread_reached_mac",
                                              "mark_read_reached_mac", "unpin_reached_mac"))
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=2)
    log("PASS" if results["pass"] else "FAIL")
    sys.exit(0 if results["pass"] else 1)


if __name__ == "__main__":
    try:
        main()
    except Fail as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
