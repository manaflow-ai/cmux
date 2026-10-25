"""Terminal sizing policy over the real link (cmux-next-ios/verify/terminal-sizing-policy.md).

Runs on the simulator host. The rig Mac (another mini) runs a hidden tagged build and
verify/scripts/sizing_probe.py, which holds a Mac pane view of each terminal and prints the
PTY grid and the size state. The probe's lines arrive in --samples (relayed), and this
driver's commands to it go to --commands (relayed to the probe's stdin): the Mac's policy is
set the way a person sets it (its cmux-next.json, which Settings > Mobile writes), and the
Mac pane's typing goes through the probe's view.

Phones: one or two headless simulators (`cmux-<tag>`), each signed in to the rig's dev
account, each opening the same workspaces over the real link (signaling + WireGuard). For
each policy and each program (Claude Code, htop, vim) it checks the Mac's grid against the
owner the policy names, reads each phone's screen (OCR) for the program's text, and
records video of every phone.

  python3 sizing_policy.py --app CmuxMobileApp.app --phones cmux-szpol-a,cmux-szpol-b \
      --samples FILE --commands FILE --workspaces szpol-claude:3,szpol-htop:4,szpol-vim:5 \
      --mac-cols 120 --mac-rows 39 --out DIR [--policies smallest,mac,...] [--one-phone]
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim, sh  # noqa: E402
from journey import Journey, BUNDLE  # noqa: E402

RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
DEVICES = ["com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
           "com.apple.CoreSimulator.SimDeviceType.iPhone-16e"]
# What each program shows on a legible screen.
MARKERS = {"claude": ["SIGWINCH", "auto mode"], "htop": ["PID", "Mem"], "vim": ["szpol-vim-line"]}


class Probe:
    def __init__(self, samples, commands):
        self.samples_path, self.commands_path = samples, commands
        self.by_surface = {}
        self.events = []
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(["tail", "-n", "0", "-F", samples], stdout=subprocess.PIPE, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                s = json.loads(line)
            except ValueError:
                continue
            s["local"] = time.time()
            with self.lock:
                if "surface" in s:
                    self.by_surface.setdefault(s["surface"], []).append(s)
                else:
                    self.events.append(s)

    def send(self, **command):
        with open(self.commands_path, "a") as f:
            f.write(json.dumps(command) + "\n")

    def latest(self, surface):
        with self.lock:
            rows = self.by_surface.get(surface) or []
            return rows[-1] if rows else None

    def settle(self, surface, want_fn, timeout=20, hold=2.0):
        """Waits until want_fn(sample) holds for `hold` seconds; returns (ok, sample, seconds)."""
        t0 = time.time()
        since = None
        s = None
        while time.time() - t0 < timeout:
            s = self.latest(surface)
            if s and want_fn(s):
                since = since or time.time()
                if time.time() - since >= hold:
                    return True, s, round(since - t0, 2)
            else:
                since = None
            time.sleep(0.2)
        return False, s, None

    def stop(self):
        self.proc.terminate()


def phones_in(sample):
    """{device_id: (cols, rows)} of the phone views that ask for a size now."""
    out = {}
    for _id, kind, _name, device, cols, rows, _counts in sample.get("participants", []):
        if kind in ("iphone", "ipad") and cols and rows:
            out[device] = (cols, rows)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--phones", required=True, help="simulator names, first is phone A")
    ap.add_argument("--samples", required=True)
    ap.add_argument("--commands", required=True)
    ap.add_argument("--workspaces", required=True, help="name:surface,... (claude, htop, vim in that order)")
    ap.add_argument("--mac-cols", type=int, default=120)
    ap.add_argument("--mac-rows", type=int, default=39)
    ap.add_argument("--policies", default="smallest,mac,latest,priority-phone,priority-mac")
    ap.add_argument("--one-phone", action="store_true", help="only phone A (the Mac + one phone set)")
    ap.add_argument("--phone-ui-policy", action="store_true", help="set Prefer This Mac once through the phone's Settings")
    ap.add_argument("--out", required=True)
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--mac-device", required=True, help="the rig Mac's cmux-mobile-host device id: other rigs share the dev account")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    mac = (a.mac_cols, a.mac_rows)
    programs = []
    for item, program in zip(a.workspaces.split(","), ("claude", "htop", "vim")):
        name, surface = item.split(":")
        programs.append((program, name, int(surface)))
    probe = Probe(a.samples, a.commands)
    names = a.phones.split(",")[: 1 if a.one_phone else None]
    sims = []
    for i, name in enumerate(names):
        udid = None
        if a.reuse:
            for devs in json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].values():
                udid = udid or next((d["udid"] for d in devs if d["name"] == name), None)
        fresh = udid is None
        if fresh:
            udid = sh("xcrun", "simctl", "create", name, DEVICES[i % len(DEVICES)], RUNTIME).strip()
        sh("xcrun", "simctl", "boot", udid, check=False)  # headless; Simulator.app is never opened
        sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
        sim = Sim(udid, shots_dir=os.path.join(a.out, "shots", name))
        j = Journey.__new__(Journey)
        j.sim, j.log, j.results, j.hangs = sim, log, [], []
        j.app_path = a.app
        if fresh:
            j.s_fresh_install()
            j.s_sign_in()
            j.s_choose_space()
        else:
            sim.launch(BUNDLE)
            sim.wait(label="Workspaces", kind="RadioButton", timeout=60)
        sims.append((name, sim, j))
        log(f"phone {name} ({udid}) ready")

    def to_list(sim, j):
        for _ in range(8):
            els = sim.tree()
            if any(e.ident == "workspaces.list" for e in els):
                return
            back = [e for e in els if e.kind == "Button" and e.label in ("Workspaces", "Back") and e.frame[1] < 120]
            done = [e for e in els if e.kind == "Button" and e.label == "Done"]
            if done:
                sim.tap_el(done[0])
            elif back:
                sim.tap_el(back[0])
            else:
                sim.drag(201, 300, 201, 870, 0.3, 20, 0.1)
            time.sleep(1.0)
        Journey.back_to_list(j)

    def connect_rig(sim):
        """Taps Connect on the rig Mac's group (other rigs share the dev account) and
        waits until its workspaces are listed (the group's fold row then goes away)."""
        fold = f"workspaces.fold.{a.mac_device}"
        for _ in range(3):
            els = sim.tree()
            e = [x for x in sim.find(ident=fold, elements=els) if x.label]
            if not e or not any(w in (e[0].label or "") for w in ("Connect", "Retry")):
                return
            btn = [x for x in els if x.label in ("Connect", "Retry") and abs(x.frame[1] - e[0].frame[1]) < 20]
            sim.tap_el(btn[0] if btn else e[0])
            t0 = time.time()
            while time.time() - t0 < 45:
                e = [x for x in sim.find(ident=fold) if x.label]
                if not e or not any(w in (e[0].label or "") for w in ("Not connected", "Can't connect")):
                    return
                time.sleep(0.5)

    def open_ws(sim, j, ws):
        to_list(sim, j)
        connect_rig(sim)
        row = sim.wait(prefix=ws, kind="Button", timeout=60)
        if not row:
            raise RuntimeError(f"workspace {ws} not listed")
        sim.tap_el(row)
        if not sim.wait(ident="terminal.composer.field", timeout=30):
            raise RuntimeError("terminal never opened")
        Journey.hide_keyboard(j)

    def tap_terminal(sim):
        # The middle of the terminal: a tap there is the phone's interaction (Prefer the Active Device).
        sim.tap(201, 360)

    def legible(sim, program, shot):
        sim.shot(shot)
        text = " ".join(t for *_, t in sim.ocr())
        hits = [m for m in MARKERS[program] if m in text]
        return bool(hits), hits

    def ids_now(surface):
        s = probe.latest(surface) or {}
        return phones_in(s)

    results = []
    device_of = {}

    def cell(policy, program, ws, surface):
        tag = f"{policy}-{program}-{len(sims)}p"
        note = []
        ok_all = True
        # Open one phone at a time: the new phone view's device id is that phone's.
        for name, sim, j in sims:
            known = set(ids_now(surface))
            open_ws(sim, j, ws)
            ok, s, _ = probe.settle(surface, lambda s: len(set(phones_in(s)) - known) >= 1 or
                                    (device_of.get(name) in phones_in(s)), timeout=30, hold=0.5)
            new = [d for d in phones_in(s or {}) if d not in known]
            if new and name not in device_of:
                device_of[name] = new[0]
            if not ok:
                note.append(f"{name} never asked for a size")
                ok_all = False
        phones = ids_now(surface)
        a_id = device_of.get(sims[0][0])
        steps = []
        if policy == "smallest":
            sizes = [mac, *phones.values()]
            steps.append(("open", (min(x[0] for x in sizes), min(x[1] for x in sizes))))
        elif policy == "mac":
            steps.append(("open", mac))
        elif policy == "priority-mac":
            steps.append(("open", mac))
        elif policy == "priority-phone":
            steps.append(("open", phones.get(a_id)))
        elif policy == "latest":
            steps.append(("open", None))
        for name, sim, j in sims:
            sim.record_start(os.path.join(a.out, f"{tag}-{name}.mp4"))
        try:
            def check_grid(label, want):
                ok, s, t = probe.settle(surface, lambda s: (s["cols"], s["rows"]) == want, timeout=20)
                g = (s or {}).get("cols"), (s or {}).get("rows")
                owners = (s or {}).get("owners")
                note.append(f"{label}: grid {g} want {want} owners {owners} {'ok' if ok else 'MISMATCH'}")
                return ok
            for label, want in steps:
                if want is not None:
                    ok_all &= check_grid(label, want)
            if policy == "latest":
                for name, sim, j in sims:
                    tap_terminal(sim)
                    want = ids_now(surface).get(device_of.get(name))
                    if want:
                        ok_all &= check_grid(f"tap on {name}", want)
                    else:
                        note.append(f"{name}: no size asked"); ok_all = False
                probe.send(op="type", surface=surface, text="\x1b")
                ok_all &= check_grid("typing in the Mac pane", mac)
            for name, sim, j in sims:
                ok, hits = legible(sim, program, f"{tag}-{name}")
                note.append(f"{name} legible {hits}")
                ok_all &= ok
            # The Connected Devices sheet on phone A, once per policy (claude only).
            if program == "claude":
                name, sim, j = sims[0]
                sim.tap(201, 830)  # the title button
                if sim.wait(label="Connected Devices…", timeout=6):
                    sim.tap_q(label="Connected Devices…")
                    grid = sim.wait(ident="sizing.grid", timeout=10)
                    sim.shot(f"{tag}-connected-devices")
                    rows = [e for e in sim.tree() if (e.ident or "").startswith("sizing.row.")]
                    note.append(f"Connected Devices: grid {grid.label if grid else None}, {len(rows)} rows")
                    ok_all &= bool(grid) and len(rows) >= 1 + len(sims)
                    sim.drag(201, 200, 201, 870, 0.3, 20, 0.1)
                else:
                    note.append("Connected Devices item not found")
                    ok_all = False
        finally:
            for name, sim, j in sims:
                sim.record_stop()
        results.append(dict(cell=tag, policy=policy, program=program, phones=len(sims), ok=ok_all, note=note))
        log(f"[{'pass' if ok_all else 'FAIL'}] {tag}: " + "; ".join(note))

    def set_policy(policy):
        a_id = device_of.get(sims[0][0])
        if policy == "priority-phone":
            probe.send(op="policy", mode="priority", order=[f"device:{a_id}", "mac"] if a_id else ["mac"])
        elif policy == "priority-mac":
            probe.send(op="policy", mode="priority", order=["mac"] + ([f"device:{a_id}"] if a_id else []))
        else:
            probe.send(op="policy", mode=policy, order=[])
        time.sleep(1.0)  # the daemon's settings watcher; the cell then waits on the grid itself

    try:
        if a.phone_ui_policy:
            name, sim, j = sims[0]
            sim.tap_q(label="Settings", kind="RadioButton")
            sim.tap_q(contains="Terminal", kind="Button")
            sim.tap_q(label="Terminal Size When Shared")
            mac_row = sim.wait(kind="Button", contains="Mac", timeout=20)
            sim.tap_el(mac_row)
            sim.tap_q(ident="sizing.mode")
            sim.tap_q(label="Prefer This Mac")
            sim.shot("phone-ui-prefer-this-mac")
            ok, s, t = probe.settle(programs[0][2], lambda s: s.get("mode") == "priority", timeout=20, hold=0.5)
            results.append(dict(cell="phone-ui-policy", ok=ok, note=[f"Mac reports mode {(s or {}).get('mode')}"]))
            log(f"[{'pass' if ok else 'FAIL'}] phone UI set Prefer This Mac: Mac mode {(s or {}).get('mode')}")
            Journey.back_to_list(j)
        for policy in a.policies.split(","):
            set_policy(policy)
            for program, ws, surface in programs:
                try:
                    cell(policy, program, ws, surface)
                except Exception as e:  # noqa: BLE001 - a broken cell is a recorded failure
                    results.append(dict(cell=f"{policy}-{program}-{len(sims)}p", ok=False, note=[f"{type(e).__name__}: {e}"]))
                    log(f"[FAIL] {policy}-{program}: {type(e).__name__}: {e}")
    finally:
        probe.stop()
        json.dump({"mac": mac, "phones": names, "results": results}, open(os.path.join(a.out, "results.json"), "w"), indent=2)
    sys.exit(0 if results and all(r["ok"] for r in results) else 1)


if __name__ == "__main__":
    main()
