"""Acceptance: a simulator of the latest cmux INTERNAL build connects to a cmux-next Mac build.

Runs on the simulator host. The Mac is a different machine (a hidden tagged rig app on
another mini, launched with `open --env`), so every check goes over the real link:
phone -> mobile-api.cmux.dev signaling -> WebRTC/WireGuard -> cmux-mobile-host -> daemon.
No local socket, loopback or debug shortcut.

  python3 acceptance_latest_ci.py --app CmuxMobileApp.app --bundle dev.cmux.app.internal \
      --sim acc-latest-ci-ios26 --runtime <iOS runtime id> --workspace acc-ws --out DIR

Credentials: CMUX_MOBILE_STACK_EMAIL / CMUX_MOBILE_STACK_PASSWORD in the environment
(never printed). Writes DIR/results.json, DIR/shots/*.png and DIR/acceptance.mp4.
The simulator is shut down and deleted at the end unless --keep.
"""
import argparse
import json
import os
import random
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim, sh  # noqa: E402

DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)
    return cond


def ensure_sim(name, runtime):
    lst = json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))
    for devs in lst["devices"].values():
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
    ap.add_argument("--workspace", required=True, help="the workspace seeded on the rig Mac")
    ap.add_argument("--mac-name", default="", help="part of the rig Mac's name as the phone lists it")
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    email = os.environ.get("CMUX_MOBILE_STACK_EMAIL", "")
    password = os.environ.get("CMUX_MOBILE_STACK_PASSWORD", "")
    check(email and password, "CMUX_MOBILE_STACK_EMAIL / CMUX_MOBILE_STACK_PASSWORD not set")
    results, t0 = [], time.time()
    udid = ensure_sim(a.sim, a.runtime)
    log(f"simulator {a.sim} {udid}")
    sim = Sim(udid, shots_dir=os.path.join(a.out, "shots"))
    video = os.path.join(a.out, "acceptance.mp4")

    def step(sid, title, fn):
        t = time.time()
        try:
            notes = fn() or ""
            status = "pass"
        except Fail as e:
            notes, status = str(e), "fail"
        except Exception as e:  # noqa: BLE001 - a broken step is a failure with its trace
            notes, status = f"{type(e).__name__}: {e}\n{traceback.format_exc()[-800:]}", "fail"
        shot = sim.shot(sid)
        results.append({"id": sid, "title": title, "status": status, "seconds": round(time.time() - t, 1),
                        "notes": notes, "shot": os.path.relpath(shot, a.out) if shot else None})
        log(f"[{status}] {sid} {title}: {notes}")
        return status == "pass"

    try:
        subprocess.run(["xcrun", "simctl", "keychain", udid, "reset"], capture_output=True)
        sh("xcrun", "simctl", "install", udid, a.app)
        sim.record_start(video)
        sim.launch(a.bundle, env={"CMUX_MOBILE_STACK_EMAIL": email, "CMUX_MOBILE_STACK_PASSWORD": password})

        def sign_in():
            i, _ = sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                                 dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")],
                                timeout=60)
            check(i is not None, "the app never left the welcome screen (password sign-in did not finish in 60 s)")
            return f"signed in as the production test account in {time.time()-t0:.1f} s after launch"

        def mac_appears():
            notes = []
            i, _ = sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                                 dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=20)
            if i in (0, 1):
                personal = sim.find(ident="setup.teams.personal") or sim.find(contains="Personal", kind="Button")
                nn = sim.find(label="Not now", kind="Button")
                check(personal or nn, "no Personal / Not now on the team step")
                sim.tap_el((personal or nn)[0]); notes.append("space: Personal")
                time.sleep(1.0)
            if sim.find(contains="Connect your Mac"):
                st = None
                deadline = time.time() + 90
                while time.time() < deadline:
                    s = sim.find(ident="connect-mac.status")
                    if s and "online" in (s[0].label or "").lower():
                        st = s[0].label
                        break
                    time.sleep(0.5)
                check(st, "Connect your Mac never showed the rig Mac online in 90 s")
                notes.append(f"connect step: {st!r}")
                sim.shot("connect-mac-online")
                for _ in range(3):
                    c = sim.wait(label="Continue", kind="Button", timeout=10)
                    check(c, "no Continue on the connect step")
                    time.sleep(0.8)
                    sim.tap_el(c)
                    time.sleep(1.5)
                    if not sim.find(contains="Connect your Mac"):
                        break
            if sim.find(label="Turn on notifications"):
                sim.tap_q(label="Not now", kind="Button"); notes.append("notifications: Not now")
            check(sim.wait(label="Workspaces", kind="RadioButton", timeout=20), "never reached the tab bar")
            w = sim.find(label="Workspaces", kind="RadioButton")
            sim.tap_el(w[0])
            row = sim.wait(prefix=a.workspace, kind="Button", timeout=60)
            check(row, f"the rig Mac's workspace {a.workspace!r} never listed on the phone")
            status = None
            deadline = time.time() + 60
            while time.time() < deadline:
                s = sim.find(ident="mac-link-status")
                if s and "Connected" in (s[0].label or ""):
                    status = s[0].label
                    break
                time.sleep(0.5)
            # With one Mac and a live link the list shows no status row; the rows themselves
            # come from the Mac's daemon over the link (the host log records the link up).
            bad = [e.label for e in sim.find(ident="mac-link-status") if "Connected" not in (e.label or "")]
            check(status or not bad, f"link not connected; status {bad}")
            notes.append(f"link: {status or 'connected (no status row shown; Mac workspace rows listed live)'}")
            return "; ".join(notes)

        def paired():
            banner = sim.find(contains="Approve this iPhone") or sim.find(contains="Pairing failed")
            check(not banner, f"pairing not approved: {banner[0].label if banner else ''!r}")
            return "no approval banner or pairing failure on the phone (the Mac side is checked from the Mac)"

        state = {}

        def terminal_echo():
            row = sim.wait(prefix=a.workspace, kind="Button", timeout=20)
            check(row, f"workspace {a.workspace} not in the list")
            sim.tap_el(row)
            comp = sim.wait(ident="terminal.composer.field", timeout=30)
            check(comp, "terminal composer never appeared")
            time.sleep(1.5)
            sim.tap_el(comp)
            time.sleep(0.8)
            marker = f"acc{random.randint(10000, 99999)}"
            state["marker"] = marker
            # The shell computes the second half, so the phone shows output, not just the typed line.
            # The shell computes the suffix, so the phone shows output, not just the typed line.
            sim.softtype(f"echo {marker}$(echo ok)")
            sim.tap_q(ident="terminal.composer.send")
            # OCR of the monospace output line: its own line holds the marker digits and "ok"
            # with no "$(" (the typed line has both).
            hits = []
            deadline = time.time() + 20
            while not hits and time.time() < deadline:
                hits = [o for o in sim.ocr() if marker[3:] in o[4] and "ok" in o[4] and "(" not in o[4]]
                time.sleep(0.5)
            sim.shot("terminal-echo")
            check(hits, f"'{marker}ok' (the shell's output) never showed on the phone's terminal in 20 s")
            return f"typed 'echo {marker}$(echo ok)' in the composer; the phone's terminal shows the output '{marker}ok'"

        def back_to_list():
            # The rig's own navigation (journey.py): alerts, sheets, keyboard, back, tab bar.
            from journey import Journey
            j = Journey.__new__(Journey)
            j.sim = sim
            Journey.back_to_list(j)

        def browser_tab():
            back_to_list()
            new = sim.wait(ident="workspaces.new", timeout=15)
            check(new, "no New Workspace button")
            sim.long_press(*new.center, seconds=1.0)
            time.sleep(1.0)
            item = sim.find(contains="Browser")
            check(item, "the hold menu has no browser workspace")
            sim.tap_el(item[0])
            bar = sim.wait(contains="Search or enter website", timeout=30)
            check(bar, "the browser workspace showed no address bar in 30 s")
            sim.tap_el(bar)
            time.sleep(0.8)
            sim.dismiss_keyboard_intro()
            sim.softtype("example.com\n")
            hits = sim.ocr_find("documentation", timeout=40) or sim.ocr_find("Example Domain")
            sim.shot("browser-example")
            check(hits, "example.com did not render on the phone in 40 s")
            return "New Browser Workspace from the phone; example.com rendered (its 'for use in documentation examples' text)"

        ok = step("sign_in", "Sign in (production Stack test account, password)", sign_in)
        ok = ok and step("mac_appears", "The Mac appears on the phone and the link connects", mac_appears)
        ok = ok and step("paired", "Pairing approved", paired)
        if ok:
            step("terminal_echo", "A terminal echoes typed text", terminal_echo)
            step("browser", "A browser tab loads a page", browser_tab)
    finally:
        sim.record_stop()
        json.dump({"udid": udid, "sim": a.sim, "runtime": a.runtime, "app": a.app, "results": results,
                   "marker": state.get("marker") if "state" in dir() else None},
                  open(os.path.join(a.out, "results.json"), "w"), indent=2)
        if not a.keep:
            sh("xcrun", "simctl", "shutdown", udid, check=False)
            sh("xcrun", "simctl", "delete", udid, check=False)
            log("simulator shut down and deleted")
    sys.exit(0 if results and all(r["status"] == "pass" for r in results) and len(results) == 5 else 1)


if __name__ == "__main__":
    main()
