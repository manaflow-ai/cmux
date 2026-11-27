#!/usr/bin/env python3
"""A native browser tab shows a Mac's localhost dev server, forwarded over the real link.

Two machines, so nothing can pass through a shared loopback: the iOS app runs in a headless
simulator on THIS mini, and the hidden rig Mac app (verify/multimac/rig.py: its own bundle id,
config and credentials) runs on ANOTHER mini, where a small web server listens on that Mac's
127.0.0.1 only. This mini cannot ssh to the rig mini, so every rig command goes through the
laptop (localhost_forward_relay.py answers `@@RIG` lines on stdin), as link_soak_relay.py does.

    python3 -u localhost_forward_live.py --app PATH --rig HOST:DIR --port PORT --nonce NONCE
        [--dead-port PORT] [--sim-name NAME] [--out DIR]

The server on the rig Mac serves a page naming NONCE whose script fetches /live.json from the
same origin and writes "fetched NONCE" into the page, so a native render proves the page and
its own requests came over the link. Steps:
1. The phone opens a browser workspace at localhost:PORT, mirrored (the Mac's browser).
2. Page Menu > Open on iPhone: the same page renders in the phone's own web view, with the
   fetched marker; this mini has nothing of its own on PORT before the phone listens.
3. localhost:DEAD-PORT (nothing listening on the Mac) shows the Mac's own reason.
4. Back shows the page again; the Mac button mirrors.
Writes DIR/results.json, run.log, shots/, phone.mp4.
"""
import argparse
import datetime
import json
import os
import shlex
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from e2e import CNX, RUNTIMES, ensure_sim  # noqa: E402
import journey  # noqa: E402
from journey import Journey  # noqa: E402
from mac import pb  # noqa: E402
from sim import Sim  # noqa: E402


class RelayedMac:
    """The rig Mac on another mini: its own CLI (rig.py cli), run by the laptop."""

    def __init__(self, host, folder):
        self.host, self.folder = host, folder

    def ssh(self, cmd, timeout=90):
        sys.stdout.write("@@RIG " + json.dumps({"host": self.host, "cmd": cmd, "timeout": timeout}) + "\n")
        sys.stdout.flush()
        reply = json.loads(sys.stdin.readline() or '{"rc": 255, "out": "", "err": "relay gone"}')
        return subprocess.CompletedProcess(cmd, reply["rc"], reply["out"], reply["err"])

    def cmux(self, *args, check=True, timeout=60, json_out=False):
        a = (["--json"] if json_out else []) + list(args)
        r = self.ssh(f"cd {self.folder} && python3 rig.py cli " + " ".join(shlex.quote(x) for x in a), timeout=timeout + 30)
        if check and r.returncode != 0:
            raise RuntimeError(f"{self.host} cmux {' '.join(args)}: {(r.stderr or r.stdout).strip()[:300]}")
        if json_out and r.returncode == 0:
            out = r.stdout.strip()
            return json.loads(out) if out else None
        return r

    def device_id(self):
        return self.ssh(f"cd {self.folder} && python3 rig.py device-id").stdout.strip()


def wait_for(pred, timeout, interval=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = pred()
        if value:
            return value
        time.sleep(interval)
    return pred()


def listening_here(port):
    """What on THIS machine listens on the port (the simulator shares its loopback)."""
    r = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], capture_output=True, text=True)
    return [line.split()[0] for line in r.stdout.splitlines()[1:]]


def main():  # noqa: C901 - one live scenario
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--rig", required=True, help="HOST:DIR of the rig Mac (verify/multimac/rig.py)")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--dead-port", type=int, default=0)
    ap.add_argument("--nonce", required=True)
    ap.add_argument("--sim-name", default="cmux-localhostfwd")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--out")
    a = ap.parse_args()

    journey.BUNDLE = pb(os.path.join(a.app, "Info.plist"), "Print :CFBundleIdentifier")
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "localhost-forward")
    shots = os.path.join(out, "shots")
    os.makedirs(shots, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        # stderr: stdout carries the relay's @@RIG lines.
        print(line, file=sys.stderr, flush=True)
        logf.write(line + "\n"); logf.flush()

    host, folder = a.rig.split(":", 1)
    mac = RelayedMac(host, folder)
    udid = ensure_sim(a.sim_name, RUNTIMES[a.ios], log)
    sim = Sim(udid, shots)
    result = {"app": a.app, "rig": a.rig, "port": a.port, "dead_port": a.dead_port, "nonce": a.nonce,
              "simulator": f"{a.sim_name} {udid}", "checks": {}, "shots": {}, "notes": {}}
    c, notes = result["checks"], result["notes"]
    rec = None

    def mirror_button():
        els = sim.tree()
        hit = [e for e in els if e.ident == "browser.mirror"] or \
              [e for e in els if (e.label or "").startswith("Mirror from") and e.kind == "Button" and e.frame[1] > 400]
        return hit[0] if hit else None

    def mirrored_shown():
        return any(e.ident in ("browser.keyboard", "browser.stream") or (e.label == "Keyboard" and e.kind == "Button")
                   for e in sim.tree())

    def native_shown():
        return mirror_button() is not None and not mirrored_shown()

    def page_menu(item):
        sim.tap_q(label="Page Menu", timeout=15)
        time.sleep(0.8)
        hit = wait_for(lambda: [e for e in sim.find(contains=item) if e.ident != "browser.mirror" and e.frame[2] > 80], 10)
        if not hit:
            raise RuntimeError(f"page menu has no {item!r}: {[e.label for e in sim.tree() if e.kind == 'Button']}")
        return hit[0]

    def address(text):
        bar = wait_for(lambda: sim.find(prefix="Address") or sim.find(prefix="Show toolbar"), 15)
        if not bar:
            raise RuntimeError("no address bar")
        sim.tap_el(bar[0])
        time.sleep(0.6)
        bar = wait_for(lambda: sim.find(prefix="Address"), 5)
        if bar:
            sim.tap_el(bar[0])
            time.sleep(0.4)
        sim.dismiss_keyboard_intro()
        sim.softtype(text + "\n")

    try:
        notes["listening_on_this_mini_before"] = listening_here(a.port)
        c["nothing_of_this_mini_on_the_port"] = not notes["listening_on_this_mini_before"]
        j = Journey(sim, mac, out, a.app, log)
        steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        if any(st["status"] != "pass" for st in steps):
            log("setup failed once; relaunching and retrying choose_space")
            sim.launch(journey.BUNDLE)
            steps = j.run(only={"choose_space", "mac_discovered"})[-2:]
        log(f"setup: {[(s['id'], s['status'], s.get('notes', '')) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            raise RuntimeError(f"setup failed: {steps}")

        path = os.path.join(out, "phone.mp4")
        rec = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1.5)

        # 1. The Mac's dev server, mirrored.
        j.back_to_list()
        new = sim.wait(ident="workspaces.new", timeout=15)
        sim.long_press(*new.center, seconds=1.0)
        time.sleep(1.0)
        sim.tap_el(wait_for(lambda: sim.find(contains="Browser"), 10)[0])
        bar = sim.wait(contains="Search or enter website", timeout=30)
        sim.tap_el(bar)
        time.sleep(0.8)
        sim.dismiss_keyboard_intro()
        sim.softtype(f"localhost:{a.port}\n")
        c["mirrored_dev_server"] = bool(sim.ocr_find(a.nonce, timeout=60))
        c["mirrored_is_the_mac_page"] = mirrored_shown()
        result["shots"]["01-mirrored"] = sim.shot("01-mirrored-mac-localhost")

        # 2. Open on iPhone: the phone's own web view, through the forward.
        sim.tap_el(page_menu("Open on iPhone"))
        c["native_shown"] = bool(wait_for(native_shown, 20))
        c["native_page_rendered"] = bool(sim.ocr_find(a.nonce, timeout=60))
        c["native_page_fetched_over_link"] = bool(sim.ocr_find("fetched", timeout=30))
        notes["listening_on_this_mini_while_native"] = listening_here(a.port)
        c["phone_listens_on_the_port"] = any("CmuxMob" in p or "Cmux" in p for p in notes["listening_on_this_mini_while_native"])
        bars = [e.label for e in sim.tree() if (e.label or "").startswith(("Address", "Show toolbar"))]
        notes["address_bar_native"] = bars
        result["shots"]["02-native"] = sim.shot("02-native-forwarded-localhost")

        # 3. A port with nothing listening on the Mac: the Mac's own reason.
        if a.dead_port:
            address(f"localhost:{a.dead_port}")
            card = wait_for(lambda: sim.find(contains=f"Nothing is listening on port {a.dead_port}"), 45)
            c["dead_port_explained"] = bool(card)
            notes["dead_port_texts"] = [e.label for e in sim.tree() if e.label and ("listening" in e.label or "reach" in e.label)][:4]
            result["shots"]["03-dead-port"] = sim.shot("03-nothing-listening-on-the-mac")
            # Back: the dev server's page again.
            sim.tap_q(label="Back", timeout=10)
            c["back_shows_the_page"] = bool(sim.ocr_find(a.nonce, timeout=30)) and native_shown()
            result["shots"]["04-back"] = sim.shot("04-back-to-the-page")

        # 4. The Mac button: back to the mirror.
        button = mirror_button()
        if button is None:
            raise RuntimeError("no Mirror from button on the phone's page")
        sim.tap_el(button)
        c["back_to_mirror"] = bool(wait_for(lambda: mirrored_shown() and mirror_button() is None, 15))
        result["shots"]["05-mirror"] = sim.shot("05-mirrored-again")
        time.sleep(2)
        notes["listening_on_this_mini_after_mirror"] = listening_here(a.port)
        c["phone_stops_listening_after_mirror"] = not any("Cmux" in p for p in notes["listening_on_this_mini_after_mirror"])

        result["pass"] = all(c.values())
        log(f"checks: {json.dumps(c)}")
        log(f"notes: {json.dumps(notes)}")
        log("PASS" if result["pass"] else "FAIL")
    finally:
        if rec:
            rec.send_signal(signal.SIGINT)
            try:
                rec.wait(20)
            except subprocess.TimeoutExpired:
                rec.kill()
        json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2)
        log(f"wrote {out}/results.json")


if __name__ == "__main__":
    main()
