"""One Mac per computer, whatever its name (PROTOCOL.md "Devices", machine id).

Rigs (rig.py folders) on cmux minis, all signed in to the same dev account and
all given ONE name (MULTIMAC_DEVICE_NAME, a Debug build's open --env setting):
two rigs on one mini run two different cmux builds (two bundle ids, two device
ids, one computer), and a rig on another mini is another computer. The phone
(headless simulator, real link) must list one Mac per computer: on the
Workspaces filter, exactly one of the shared mini's builds plus the other
mini's rig. Settings > Devices lists every build and marks the other build.

    python3 multimac_machine_id.py --app PATH --udid UDID --name NAME
        --rig HOST:DIR --rig HOST:DIR --rig HOST:DIR [--keep-install] [--out DIR]

Rigs on the same HOST are one computer. Writes DIR/results.json, run.log, shots/.
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


class Rig:
    def __init__(self, spec):
        self.host, self.dir = spec.split(":", 1)

    def run(self, *args, timeout=90):
        cmd = f"cd {self.dir} && python3 rig.py " + " ".join(f"'{a}'" for a in args)
        return subprocess.run(["ssh", "-o", "ConnectTimeout=10", self.host, cmd], capture_output=True, text=True, timeout=timeout)

    def device_id(self):
        return self.run("device-id").stdout.strip().lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--name", required=True, help="the one name every rig registered")
    ap.add_argument("--rig", action="append", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "evidence", time.strftime("%Y%m%d-%H%M%S") + "-machine-id"))
    ap.add_argument("--keep-install", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rigs = [Rig(r) for r in a.rig]
    computers = {}
    for rig in rigs:
        rig.device = rig.device_id()
        check(rig.device, f"{rig.host}:{rig.dir} has no device id (not registered yet?)")
        computers.setdefault(rig.host, []).append(rig.device)
        log(f"rig {rig.host}:{rig.dir} device {rig.device[:8]}")
    mine = {rig.device for rig in rigs}
    sim = Sim(a.udid, shots_dir=os.path.join(a.out, "shots"))
    j = Journey(sim, rigs[0], a.out, a.app, log)
    results = {"name": a.name, "computers": {h: [d[:8] for d in ds] for h, ds in computers.items()}, "checks": {}}
    if not a.keep_install:
        j.s_fresh_install()
        j.s_sign_in()
        j.s_choose_space()
    log("signed in")

    # Workspaces filter: one row per computer.
    j.back_to_list()
    rows = []
    deadline = time.time() + 90
    while True:
        # The menu lists the Macs the phone knew when it opened: open, read, close, again.
        sim.tap_q(ident="workspaces.filter", timeout=60)
        sim.wait(ident="workspaces.filter.all", timeout=10)
        rows = [e for e in sim.find(ident="workspaces.filter.*") if e.ident and e.ident[len("workspaces.filter."):] in mine]
        if len({r.ident for r in rows}) >= len(computers) or time.time() > deadline:
            break
        sim.tap_q(ident="workspaces.filter", timeout=10)
        time.sleep(3)
    sim.shot("01-filter-one-row-per-computer")
    listed = sorted({r.ident[len("workspaces.filter."):] for r in rows})
    labels = sorted({r.label for r in rows})
    log(f"filter lists {len(listed)} of my rigs: {[d[:8] for d in listed]} labels {labels}")
    per_computer = {h: [d for d in ds if d in listed] for h, ds in computers.items()}
    results["checks"]["filter_rows"] = len(listed)
    results["checks"]["filter_labels"] = labels
    results["checks"]["per_computer"] = {h: [d[:8] for d in ds] for h, ds in per_computer.items()}
    ok_filter = len(listed) == len(computers) and all(len(ds) == 1 for ds in per_computer.values())
    sim.tap_q(label="All Macs", timeout=10)

    # Settings > Devices: every build listed; the other build on the shared mini marked.
    j.tab("Settings")
    sim.tap_q(contains="Devices", timeout=20)
    devices = []
    deadline = time.time() + 30
    while time.time() < deadline:
        devices = [e for e in sim.find(ident="settings.pairedMacs.*") if e.ident[len("settings.pairedMacs."):] in mine]
        if len(devices) >= len(rigs):
            break
        time.sleep(1)
    sim.shot("02-settings-devices-every-build")
    marked = [e.ident[len("settings.pairedMacs."):] for e in devices if "Another cmux build on this Mac" in (e.label or "")]
    log(f"settings lists {len(devices)} of my rigs; marked as another build: {[d[:8] for d in marked]}")
    results["checks"]["settings_rows"] = len(devices)
    results["checks"]["settings_marked_other_build"] = [d[:8] for d in marked]
    shared = [ds for ds in computers.values() if len(ds) > 1]
    ok_settings = len(devices) == len(rigs) and len(marked) == sum(len(ds) - 1 for ds in shared) \
        and all(m not in listed for m in marked)
    results["pass"] = ok_filter and ok_settings
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=2)
    log(("PASS" if results["pass"] else "FAIL") + f": filter {ok_filter}, settings {ok_settings}")
    sys.exit(0 if results["pass"] else 1)


if __name__ == "__main__":
    try:
        main()
    except Fail as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
