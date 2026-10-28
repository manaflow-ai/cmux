"""Size release over the real link: does the Mac pane get its own size back on every path?

Runs on the simulator host against a hidden rig Mac on another mini (the acceptance rig:
acceptance-latest-ci-20261021.md). The rig Mac runs verify/scripts/size_probe.py against its
cmux-tui daemon, which prints the terminal's PTY grid (what the Mac pane shows) every 0.2 s;
this driver reads that stream over ssh, drives the phone through each path and records the
grid before, during and after, and the time from the action until the grid is the Mac's again.

  python3 size_release.py --app CmuxMobileApp.app --bundle dev.cmux.app.internal \
      --sim msr-ios26 --runtime <iOS runtime id> --workspace msr-ws \
      --mac-ssh mini-cmux11s-mac-mini --mac-socket <daemon socket on the rig Mac> \
      --surface N --mac-cols 120 --mac-rows 39 --out DIR [--paths a,b,c]

Credentials: CMUX_MOBILE_STACK_EMAIL / CMUX_MOBILE_STACK_PASSWORD (never printed).
"""
import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim, sh  # noqa: E402

DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


class Probe:
    """The rig Mac's grid samples, read from size_probe.py over ssh."""

    def __init__(self, host, socket_path, surface, probe_path, policy=None, mac_view=None, samples_file=None):
        if samples_file:
            # The probe runs elsewhere and its lines are relayed into this file
            # (the simulator host cannot reach the rig Mac); read them as they land.
            argv = ["tail", "-n", "0", "-F", samples_file]
        else:
            cmd = ["python3", "-u", probe_path, "--socket", socket_path, "--surface", str(surface)]
            if mac_view:
                cmd += ["--mac-view", mac_view]
            if policy:
                cmd += ["--policy", policy]
            argv = ["ssh", "-o", "ServerAliveInterval=10", host,
                    " ".join(c if c.startswith("~") else f"'{c}'" for c in cmd)]
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.samples = []
        self.lock = threading.Lock()
        self.q = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                s = json.loads(line)
            except ValueError:
                continue
            s["local"] = time.time()
            with self.lock:
                self.samples.append(s)

    def latest(self):
        with self.lock:
            return self.samples[-1] if self.samples else None

    def grid(self):
        s = self.latest()
        return (s["cols"], s["rows"]) if s else None

    def wait_grid(self, want, timeout, since=None):
        """Seconds from `since` until the grid is `want` (None: not within timeout)."""
        since = since or time.time()
        deadline = since + timeout
        while time.time() < deadline:
            with self.lock:
                hit = next((s for s in self.samples if s["local"] >= since and (s["cols"], s["rows"]) == want), None)
            if hit:
                return round(hit["local"] - since, 2)
            time.sleep(0.1)
        return None

    def stays(self, want, seconds):
        """True when every sample for `seconds` is `want`."""
        start = time.time()
        while time.time() - start < seconds:
            g = self.grid()
            if g != want:
                return False, g
            time.sleep(0.2)
        return True, want

    def stop(self):
        self.proc.terminate()


def ensure_sim(name, runtime):
    for devs in json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].values():
        for d in devs:
            if d["name"] == name:
                sh("xcrun", "simctl", "delete", d["udid"], check=False)
    udid = sh("xcrun", "simctl", "create", name, DEVICE, runtime).strip()
    sh("xcrun", "simctl", "boot", udid)  # headless; Simulator.app is never opened
    sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
    return udid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--sim", required=True)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--mac-ssh", default="")
    ap.add_argument("--samples-file", help="read the probe's lines from this file (relayed) instead of ssh")
    ap.add_argument("--mac-socket", default="")
    ap.add_argument("--mac-probe", default="~/msr-20261021/size_probe.py")
    ap.add_argument("--surface", type=int, required=True)
    ap.add_argument("--mac-cols", type=int, required=True)
    ap.add_argument("--mac-rows", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--paths", default="")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--reuse", action="store_true", help="keep the signed-in simulator of a previous run")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    email = os.environ.get("CMUX_MOBILE_STACK_EMAIL", "")
    password = os.environ.get("CMUX_MOBILE_STACK_PASSWORD", "")
    if not (email and password):
        sys.exit("CMUX_MOBILE_STACK_EMAIL / CMUX_MOBILE_STACK_PASSWORD not set")
    mac = (a.mac_cols, a.mac_rows)
    probe = Probe(a.mac_ssh, a.mac_socket, a.surface, a.mac_probe, policy="smallest",
                  mac_view=f"{a.mac_cols}x{a.mac_rows}", samples_file=a.samples_file)
    deadline = time.time() + 15
    while probe.grid() is None and time.time() < deadline:
        time.sleep(0.2)
    log(f"probe: Mac grid {probe.grid()} (Mac pane {mac})")

    udid = None
    if a.reuse:
        for devs in json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].values():
            udid = udid or next((d["udid"] for d in devs if d["name"] == a.sim), None)
    fresh = udid is None
    udid = udid or ensure_sim(a.sim, a.runtime)
    sim = Sim(udid, shots_dir=os.path.join(a.out, "shots"))
    results = []
    from journey import Journey
    j = Journey.__new__(Journey)
    j.sim = sim

    def launch():
        sim.launch(a.bundle, env={"CMUX_MOBILE_STACK_EMAIL": email, "CMUX_MOBILE_STACK_PASSWORD": password})

    def to_list():
        """The Workspaces list: the grid's Done, the workspace's top-left back
        ("Workspaces"), a sheet swiped down; else the rig journey's walk."""
        for _ in range(8):
            els = sim.tree()
            if any(e.ident == "workspaces.list" for e in els):
                return
            done = [e for e in els if e.kind == "Button" and e.label == "Done" and 700 < e.frame[1] < 874]
            back = [e for e in els if e.kind == "Button" and e.label == "Workspaces" and e.frame[1] < 120]
            if done:
                sim.tap_el(done[0])
            elif back:
                sim.tap_el(back[0])
            elif sim.find(label="Back", kind="Button", elements=els):
                sim.tap_el(sim.find(label="Back", kind="Button", elements=els)[0])
            else:
                sim.drag(201, 300, 201, 870, 0.3, 20, 0.1)
            time.sleep(1.0)
        Journey.back_to_list(j)

    def open_terminal():
        """Opens the workspace's terminal and waits until the phone sizes the Mac's grid."""
        to_list()
        row = sim.wait(prefix=a.workspace, kind="Button", timeout=60)
        if not row:
            raise RuntimeError(f"workspace {a.workspace} not listed")
        sim.tap_el(row)
        if not sim.wait(ident="terminal.composer.field", timeout=30):
            raise RuntimeError("terminal never opened")
        t = time.time()
        deadline = t + 20
        while time.time() < deadline:
            g = probe.grid()
            if g and g != mac:
                return g, round(time.time() - t, 2)
            time.sleep(0.1)
        raise RuntimeError(f"the phone never sized the Mac's grid (still {probe.grid()})")

    def record(path, mechanism, action, bound, expect_hold=None):
        """Opens the terminal, does `action`, measures until the Mac's grid is back."""
        try:
            phone, claim = open_terminal()
            before = probe.grid()
            sim.shot(f"{path}-before")
            t = time.time()
            note = action() or ""
            done = time.time()  # the driver's taps and waits end here: the app's bound starts
            if expect_hold:
                held, g = probe.stays(phone, expect_hold)
                note += f"; held {phone} for {expect_hold}s: {held} ({g})"
            since_start = probe.wait_grid(mac, bound + 15, since=t)
            # From the action's end; a grid already back before it ends counts as 0.
            restored = None if since_start is None else round(max(0.0, since_start - (done - t)), 2)
            after = probe.grid()
            ok = restored is not None and restored <= bound + 0.5
            results.append(dict(path=path, mechanism=mechanism, before=before, phone=phone, claim_s=claim,
                                restored_s=restored, restored_from_action_start_s=since_start,
                                driver_action_s=round(done - t, 2), after=after, bound_s=bound, ok=ok, note=note))
            log(f"[{'pass' if ok else 'FAIL'}] {path}: before {before} phone {phone} -> Mac {mac} in {restored}s "
                f"after the action ({since_start}s from its start; bound {bound}s) {note}")
        except Exception as e:  # noqa: BLE001 - a broken path is a recorded failure
            results.append(dict(path=path, mechanism=mechanism, ok=False, note=f"{type(e).__name__}: {e}"))
            log(f"[FAIL] {path}: {type(e).__name__}: {e}")
        finally:
            sim.shot(f"{path}-after")
            reset_ui()

    def reset_ui():
        if not sim.find(label="Workspaces", kind="RadioButton") and not sim.find(ident="terminal.composer.field"):
            sim.launch(a.bundle, env={"CMUX_MOBILE_STACK_EMAIL": email, "CMUX_MOBILE_STACK_PASSWORD": password},
                       terminate=False)
            time.sleep(3)
        """Back to the list for the next path: dismiss what is open, else relaunch the app
        (a relaunch is a link drop the next path's open waits out)."""
        close_grid()
        try:
            to_list()
        except Exception:  # noqa: BLE001
            launch(); time.sleep(4)
            to_list()
        # The previous path's release lands before the next path opens the terminal.
        probe.wait_grid(mac, 50)

    def back():
        to_list()

    def tab_grid():
        Journey.hide_keyboard(j)
        sim.tap_q(label="Tabs", kind="Button")
        return "tab grid open"

    def close_grid():
        done = [e for e in sim.find(kind="Button", label="Done") if 700 < e.frame[1] < 874]
        if done:
            sim.tap_el(done[0]); time.sleep(1.0)

    def files_sheet():
        Journey.hide_keyboard(j)
        title = [e for e in sim.find(kind="Button") if e.frame[1] > 780 and e.frame[2] > 150]
        sim.tap_el(title[0]); time.sleep(1.0)
        sim.tap_q(label="Files and Links", timeout=6)
        return "Files and Links open"

    def background():
        sim.home()
        return "home button (app to background)"

    def quick_switch():
        # Away and back inside the 1 s debounce, five times: no resize at all.
        g0 = probe.grid()
        changes = 0
        Journey.hide_keyboard(j)
        sim.wait(label="Tabs", kind="Button", timeout=20)
        for _ in range(5):
            sim.tap_q(label="Tabs", kind="Button"); time.sleep(0.3)
            close_grid(); time.sleep(0.3)
        time.sleep(2.0)
        with probe.lock:
            recent = [s for s in probe.samples if s["local"] > time.time() - 6]
        grids = {(s["cols"], s["rows"]) for s in recent}
        changes = len(grids) - 1
        return f"5 quick grid opens: grids seen {sorted(grids)} (start {g0}); changes {changes}"

    def kill():
        sim.terminate(a.bundle)
        return "app terminated (force quit)"

    paths = [
        ("back", "page disappears -> release after 1 s debounce", back, 1.0 + 1.0),
        ("tab_grid", "page not interactive -> release after 1 s", tab_grid, 2.0),
        ("files_sheet", "covered by its own sheet -> release after 1 s", files_sheet, 2.0),
        ("background", "didEnterBackground -> release at once", background, 1.0),
        ("force_quit", "no release; the hold ends with the 45 s lease", kill, 45.0),
    ]
    wanted = set(filter(None, a.paths.split(",")))
    try:
        if fresh:
            subprocess.run(["xcrun", "simctl", "keychain", udid, "reset"], capture_output=True)
            sh("xcrun", "simctl", "install", udid, a.app)
        launch()
        i, _ = sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                             dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=90)
        log(f"signed in ({i})")
        # Onboarding to the list, as acceptance_latest_ci.py does.
        if i in (0, 1):
            p = sim.find(ident="setup.teams.personal") or sim.find(label="Not now", kind="Button")
            if p:
                sim.tap_el(p[0]); time.sleep(1)
        for _ in range(3):
            if not sim.find(contains="Connect your Mac"):
                break
            c = sim.wait(label="Continue", kind="Button", timeout=60)
            if c:
                time.sleep(0.8); sim.tap_el(c); time.sleep(1.5)
        if sim.find(label="Turn on notifications"):
            sim.tap_q(label="Not now", kind="Button")
        for name, mech, action, bound in paths:
            if wanted and name not in wanted:
                continue
            if name in ("force_quit", "background"):
                # The app is gone or in the background: bring it back first, then reset.
                orig = action
                def action(orig=orig):
                    return orig()
                record_then = record
                record_then(name, mech, action, bound)
                continue
            record(name, mech, action, bound)
        if "open_only" in wanted:
            # Leaves the terminal open and sized for a Mac-side path the caller drives.
            phone, claim = open_terminal()
            Journey.hide_keyboard(j)
            results.append(dict(path="open_only", phone=phone, claim_s=claim, ok=True, at=time.time()))
            log(f"[pass] open_only: phone {phone} after {claim}s; terminal left open")
        if not wanted or "quick_switch" in wanted:
            try:
                phone, _ = open_terminal()
                note = quick_switch()
                ok = "changes 0" in note
                results.append(dict(path="quick_switch", mechanism="1 s debounce: nothing sent", phone=phone,
                                    ok=ok, note=note))
                log(f"[{'pass' if ok else 'FAIL'}] quick_switch: {note}")
            except Exception as e:  # noqa: BLE001
                results.append(dict(path="quick_switch", ok=False, note=str(e)))
                log(f"[FAIL] quick_switch: {e}")
    finally:
        probe.stop()
        json.dump({"mac": mac, "results": results}, open(os.path.join(a.out, "results.json"), "w"), indent=2)
        if not a.keep:
            sh("xcrun", "simctl", "shutdown", udid, check=False)
            sh("xcrun", "simctl", "delete", udid, check=False)
    sys.exit(0 if results and all(r.get("ok") for r in results) else 1)


if __name__ == "__main__":
    main()
