#!/usr/bin/env python3
"""Invite to cmux (the Chief header's trailing button) over the real link.

Runs ON a cmux mini: the hidden e2e rig Mac (mac.py: its own bundle id, config and
credentials, launched with `open -g -j`, never activated) and the iOS app in one
headless simulator driven with AXe (accessibility taps on that simulator only).

    python3 chief_invite_live.py --mac-app PATH --app PATH [--sim-name cmux-chiefinv] [--out DIR]

With Chief open, in light and dark: the trailing button's label, the share sheet (its
preview header and the text it shares: Copy, then the simulator's pasteboard), and
Messages' compose with the preview if the sheet offers Messages. Then Chief's info
from the header's name and from the avatar. Writes DIR/results.json, run.log, shots/.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from e2e import CNX, RUNTIMES, ensure_sim  # noqa: E402
import journey  # noqa: E402
from journey import Journey  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402

from chief_info_live import appearance, close_info, on_info, open_chief  # noqa: E402


# The share sheet runs in another process: its buttons are not in the app's
# accessibility tree, so it is read from the screen (OCR) and tapped by place
# (iPhone 17 Pro, 402 x 874 pt: Copy at 68,384; outside the card at 200,700).
COPY = (68, 384)
OUTSIDE = (200, 700)


def sheet_up(sim):
    # The preview's link line (OCR can read Copy's C as a Cyrillic letter).
    return any("cmux.com" in o[4] and o[1] < 500 for o in sim.ocr())


def close_sheet(sim):
    sim.tap(*OUTSIDE)
    time.sleep(1.5)


def pasteboard(udid):
    return subprocess.run(["xcrun", "simctl", "pbpaste", udid], capture_output=True, text=True).stdout


def main():  # noqa: C901 - one live scenario
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--sim-name", default="cmux-chiefinv")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--out")
    a = ap.parse_args()

    mac_app = os.path.abspath(a.mac_app)
    # The rig's journey drives the app by its bundle id; a tagged Demo build has its own.
    journey.BUNDLE = pb(os.path.join(a.app, "Info.plist"), "Print :CFBundleIdentifier")
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "chief-invite")
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app, cleanup=True, log=log).prepare()
    mac.seed_pairing(names=[a.sim_name])
    udid = ensure_sim(a.sim_name, RUNTIMES[a.ios], log)
    sim = Sim(udid, os.path.join(out, "shots"))
    result = {"app": a.app, "mac_app": os.path.basename(mac_app), "simulator": f"{a.sim_name} {udid}", "checks": {}, "shots": {}}
    c = result["checks"]
    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}), host {'running' if mac.wait_hostd(120) else 'NOT running'}")
        j = Journey(sim, mac, out, a.app, log)
        steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        if any(st["status"] != "pass" for st in steps):
            log("setup failed once; relaunching and retrying choose_space")
            sim.launch(journey.BUNDLE)
            steps = j.run(only={"choose_space", "mac_discovered"})[-2:]
        log(f"setup: {[(s['id'], s['status']) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            raise RuntimeError(f"setup failed: {steps}")
        appearance(udid, "light")
        c["chief_loaded"] = open_chief(j)
        time.sleep(2)
        for mode in ("light", "dark"):
            appearance(udid, mode)
            trailing = sim.find(ident="conversation.header.trailing")
            c[f"trailing_label_{mode}"] = trailing[0].label if trailing else None
            result["shots"][f"chief-{mode}"] = sim.shot(f"01-chief-{mode}")
            sim.tap_q(ident="conversation.header.trailing")
            time.sleep(2.5)
            c[f"sheet_up_{mode}"] = sheet_up(sim)
            c[f"sheet_ocr_{mode}"] = [o[4] for o in sim.ocr()]
            result["shots"][f"sheet-{mode}"] = sim.shot(f"02-share-sheet-{mode}")
            if mode == "light":
                # What the share sends: Copy puts the items on the pasteboard and closes the sheet.
                subprocess.run(["xcrun", "simctl", "pbcopy", udid], input="", text=True)
                sim.tap(*COPY); time.sleep(2)
                c["copied_text"] = pasteboard(udid)
                c["copy_closes_sheet"] = not sheet_up(sim)
                log(f"copied: {c['copied_text']!r}")
                sim.tap_q(ident="conversation.header.trailing"); time.sleep(2.5)
                # The simulator has no Messages account, so the sheet offers no Messages.
                c["sheet_offers_messages"] = "Messages" in " ".join(o[4] for o in sim.ocr() if o[1] < 500)
            if sheet_up(sim):
                close_sheet(sim)
            c[f"sheet_closed_{mode}"] = not sheet_up(sim)
        appearance(udid, "light")
        # Chief's info is still one tap away: the header's name, then the avatar.
        c["back_in_conversation_before_info"] = bool(sim.find(ident="conversation.transcript"))
        sim.tap_q(ident="conversation.header.name")
        c["name_opens_info"] = bool(sim.wait(timeout=10, ident="chief.settings")) and (time.sleep(1.8) or on_info(sim))
        result["shots"]["info-from-name"] = sim.shot("04-info-from-name")
        close_info(sim)
        avatar = [e for e in sim.tree() if e.label == "Chief" and e.kind == "Button" and e.frame[1] < 140
                  and e.ident != "conversation.header.name"]
        if avatar:
            sim.tap_el(avatar[0])
            c["avatar_opens_info"] = bool(sim.wait(timeout=10, ident="chief.settings")) and (time.sleep(1.8) or on_info(sim))
            result["shots"]["info-from-avatar"] = sim.shot("05-info-from-avatar")
            close_info(sim)
        else:
            c["avatar_opens_info"] = None
        c["back_in_conversation"] = bool(sim.find(ident="conversation.transcript"))
        log(f"checks: {json.dumps({k: v for k, v in c.items() if 'texts' not in k})}")
    finally:
        try:
            # The app, then its acpmux daemons, Chief host and headless cmux-tui, which
            # outlive it (rig_cleanup.py); leftovers only by exact PID. First, so a
            # simulator failure below never leaves them running.
            mac.teardown()
        except Exception as e:  # noqa: BLE001
            log(f"teardown: {e}")
        try:
            appearance(udid, "light")
        except Exception as e:  # noqa: BLE001
            log(f"appearance: {e}")
        json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2)
        log(f"wrote {out}/results.json")


if __name__ == "__main__":
    main()
