"""Two Macs at once over the real link (PROTOCOL.md "One link per Mac").

One headless simulator on this laptop runs the iOS app; two hidden rig Mac apps
(real tagged cmux-next builds, isolated, settings only through `open --env`) run
on two cmux minis, signed in to the same dev account. The phone opens a terminal
on each Mac and types on both alternately for `--seconds`; every line must reach
its own Mac's terminal (read back through that Mac's own CLI, never the phone),
and neither Mac's host may log a `link down` for the phone meanwhile.

    python3 multimac_live.py --app PATH --rig HOST:WORKSPACE:TERMINAL --rig HOST:WORKSPACE:TERMINAL
                             [--seconds 120] [--out DIR] [--udid UDID]

Each rig is a ~/multimac-rig on its mini (rig.py there: `cli`, `link-events`).
Writes DIR/results.json, DIR/run.log, DIR/shots/ and DIR/multimac.mp4.
"""
import argparse
import json
import os
import random
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from journey import Fail, Journey, check  # noqa: E402
from sim import Sim  # noqa: E402

BUNDLE = "dev.cmux.mobile"
PHONE = "multimac-phone"


class RemoteRig:
    """A rig Mac app on a mini, driven only through its own CLI over ssh."""

    def __init__(self, host, workspace, terminal):
        self.host, self.workspace, self.terminal = host, workspace, terminal

    def ssh(self, cmd, timeout=90):
        return subprocess.run(["ssh", "-o", "ConnectTimeout=10", self.host, cmd], capture_output=True, text=True, timeout=timeout)

    def cmux(self, *args, check=True, timeout=60, json_out=False):
        a = (["--json"] if json_out else []) + list(args)
        r = self.ssh("cd ~/multimac-rig && python3 rig.py cli " + " ".join(shlex.quote(x) for x in a), timeout=timeout + 30)
        if check and r.returncode != 0:
            raise RuntimeError(f"{self.host} cmux {' '.join(args)}: {(r.stderr or r.stdout).strip()[:300]}")
        if json_out and r.returncode == 0:
            out = r.stdout.strip()
            return json.loads(out) if out else None
        return r

    def device_id(self):
        return self.ssh("cd ~/multimac-rig && python3 rig.py device-id").stdout.strip()

    def link_events(self, since):
        r = self.ssh(f"cd ~/multimac-rig && python3 rig.py link-events {since}")
        return json.loads(r.stdout or "[]")

    def screen(self):
        return (self.cmux("terminal", self.terminal, "screen", "read", json_out=True) or {}).get("text", "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--rig", action="append", required=True, help="HOST:WORKSPACE_NAME:TERMINAL_ID")
    ap.add_argument("--seconds", type=float, default=120)
    ap.add_argument("--out", default=os.path.join(HERE, "evidence", time.strftime("%Y%m%d-%H%M%S")))
    ap.add_argument("--udid")
    ap.add_argument("--keep-install", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rigs = [RemoteRig(*r.split(":")) for r in a.rig]
    check(len(rigs) == 2, "two rigs")
    for rig in rigs:
        rig.device = rig.device_id()
        log(f"rig {rig.host}: device {rig.device}, workspace {rig.workspace}, terminal {rig.terminal}")
    sim = Sim(a.udid, shots_dir=os.path.join(a.out, "shots"))
    j = Journey(sim, rigs[0], a.out, a.app, log)
    results = {"rigs": [{"host": r.host, "device": r.device, "workspace": r.workspace} for r in rigs], "steps": []}

    if not a.keep_install:
        j.s_fresh_install()
        j.s_sign_in()
        j.s_choose_space()
    log("signed in; on the tab bar")

    # Both Macs listed, then each workspace row.
    j.back_to_list()
    for rig in rigs:
        check(sim.wait(prefix=rig.workspace, kind="Button", timeout=60), f"{rig.workspace} ({rig.host}) not listed on the phone")
    sim.shot("list-both")
    log("both Macs' workspaces listed")

    video = os.path.join(a.out, "multimac.mp4")
    sim.record_start(video)
    t0 = time.time()
    rounds = []
    try:
        n = 0
        while time.time() - t0 < a.seconds:
            rig = rigs[n % 2]
            n += 1
            j.back_to_list()
            row = sim.wait(prefix=rig.workspace, kind="Button", timeout=30)
            check(row, f"{rig.workspace} row missing (round {n})")
            sim.tap_el(row)
            check(sim.wait(ident="terminal.composer.field", timeout=30), f"{rig.workspace}: no terminal (round {n})")
            j.focus_terminal()
            marker = f"mm{n:03d}x{random.randint(1000, 9999)}"
            t_type = time.time()
            sim.softtype(f"echo {marker}\n")
            deadline = time.time() + 20
            seen = False
            while time.time() < deadline:
                if rig.screen().count(marker) >= 2:
                    seen = True
                    break
                time.sleep(0.3)
            other = rigs[n % 2]
            leaked = marker in other.screen()
            rec = {"round": n, "mac": rig.host, "marker": marker, "reached": seen,
                   "echo_s": round(time.time() - t_type, 2), "leaked_to_other_mac": leaked}
            rounds.append(rec)
            log(f"round {n}: {rig.host} {marker} reached={seen} in {rec['echo_s']} s leaked={leaked}")
            if n <= 2:
                sim.shot(f"round-{n}-{rig.host}")
            check(seen, f"round {n}: '{marker}' never reached {rig.host}")
            check(not leaked, f"round {n}: '{marker}' reached the other Mac")
            j.hide_keyboard()
    finally:
        sim.record_stop()
    elapsed = time.time() - t0
    downs = {rig.host: [e for e in rig.link_events(t0) if e[1] == "down"] for rig in rigs}
    ups = {rig.host: [e for e in rig.link_events(t0) if e[1] == "up"] for rig in rigs}
    log(f"link events since start: down {downs} up {ups}")
    results.update(rounds=rounds, seconds=round(elapsed, 1), link_down=downs, link_up=ups, video=video)
    ok = all(r["reached"] and not r["leaked_to_other_mac"] for r in rounds) and len(rounds) >= 4 \
        and not any(downs.values()) and not any(ups.values()) and elapsed >= a.seconds
    results["pass"] = ok
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=2)
    log(f"{'PASS' if ok else 'FAIL'}: {len(rounds)} rounds in {elapsed:.0f} s, both links stayed up: {not any(downs.values())}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    try:
        main()
    except Fail as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
