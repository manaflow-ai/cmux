#!/usr/bin/env python3
"""Chief's info page over the real link, measured against Messages' contact details.

Runs ON a cmux mini: the hidden e2e rig Mac (mac.py: its own bundle id, config and
credentials, launched with `open -g -j`, never activated) and the iOS app in one
headless simulator driven with AXe (accessibility taps on that simulator only).

    python3 chief_info_live.py --mac-app PATH --app PATH --label before|after
                               [--sim-name cmux-chiefinfo] [--reuse] [--out DIR]

For each state (Chief connected, then the rig Mac quit: disconnected) and each
appearance (light, dark) it opens Chief, opens Chief's info from the header's
name, and records:

- the navigation buttons' centers (Done in the old sheet; Back and Edit now);
- the avatar's frame (its own element now; the old sheet's header element, whose
  top is the 72 pt avatar's top), the name's line box (AX) and glyph box (OCR);
- the first card row's top;
- Messages' numbers for the same phone (CmuxConversation's
  ConversationDetailsHeaderGeometry, read from MobileSMS on iOS 26.5): avatar 80 pt,
  its top at the status bar's bottom, the title's line box 84 pt below the avatar's top.

Then (the new page only) it checks that the controls still act: Hide Alerts toggles
and back, Edit opens Name, Message returns to the conversation with the keyboard up,
and the edge swipe pops back. Writes DIR/results.json, DIR/run.log and DIR/shots/.
"""
import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from e2e import CNX, RUNTIMES, ensure_sim  # noqa: E402
from journey import BUNDLE, Journey  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402

MESSAGES = {"avatar": 80, "avatar_top_from_safe_top": 0, "title_top_from_avatar_top": 84}
NAV_LABELS = ("Done", "Back", "Edit")


def frame_dict(f):
    x, y, w, h = f
    return {"x": round(x, 2), "y": round(y, 2), "w": round(w, 2), "h": round(h, 2),
            "cx": round(x + w / 2, 2), "cy": round(y + h / 2, 2)}


def measure(sim, name):
    els = sim.tree()
    out = {}
    nav = [e for e in els if e.kind == "Button" and e.frame[1] < 130 and e.frame[0] >= 0
           and (e.label in NAV_LABELS or e.ident in ("chief.settings.done", "chief.settings.edit", "BackButton"))]
    out["nav"] = {(e.label or e.ident): frame_dict(e.frame) for e in nav}
    avatar = [e for e in els if e.ident == "chief.settings.avatarImage"]
    if avatar:
        out["avatar"] = frame_dict(avatar[0].frame)
        out["avatar_source"] = "element"
    else:
        # The old sheet: one combined header element; its top is the 72 pt avatar's top.
        head = [e for e in els if (e.label or "").startswith(name) and e.frame[2] > 250 and e.frame[1] < 450]
        if head:
            x, y, w, _ = head[0].frame
            out["avatar"] = frame_dict((x + w / 2 - 36, y, 72, 72))
            out["avatar_source"] = "header element top, 72 pt avatar"
    title = [e for e in els if e.ident == "chief.settings.title"]
    if title:
        out["title_ax"] = frame_dict(title[0].frame)
    glyphs = [o for o in sim.ocr() if o[4].strip() == name and o[1] < 450]
    if glyphs:
        out["title_ocr"] = frame_dict(glyphs[0][:4])
    rows = [e for e in els if e.frame[1] > 150 and e.frame[0] >= 0 and (
        e.ident in ("chief.settings.harness", "chief.settings.lastModel", "chief.settings.hideAlerts")
        or (e.label or "").startswith(("Connect to your Mac", "Asking Chief", "This Chief runs")))]
    if rows:
        out["first_row_top"] = round(min(e.frame[1] for e in rows), 2)
    quick = [e for e in els if e.ident in ("chief.settings.message", "chief.settings.stop")]
    out["quick_actions"] = {e.ident: frame_dict(e.frame) for e in quick}
    texts = [e.label for e in els if e.label and e.frame[0] >= 0][:60]
    out["texts"] = texts
    a = out.get("avatar")
    if a:
        for label, f in out["nav"].items():
            out[f"avatar_cy_minus_{label}_cy"] = round(a["cy"] - f["cy"], 2)
        if "title_ax" in out:
            out["title_line_top_minus_avatar_top"] = round(out["title_ax"]["y"] - a["y"], 2)
            out["avatar_bottom_to_title_line"] = round(out["title_ax"]["y"] - (a["y"] + a["h"]), 2)
        if "title_ocr" in out:
            out["avatar_bottom_to_title_glyphs"] = round(out["title_ocr"]["y"] - (a["y"] + a["h"]), 2)
        nav_bottom = max((f["y"] + f["h"] for f in out["nav"].values()), default=None)
        if nav_bottom is not None:
            out["gap_nav_bottom_to_avatar_top"] = round(a["y"] - nav_bottom, 2)
    return out


def open_chief(j):
    """Home > the Mac's Chief (the rig Mac's own Chief over the link)."""
    j.back_to_list()
    j.tab("Home")
    tile = j.sim.wait(ident="home.chief.mac", timeout=90)
    if not tile:
        raise RuntimeError("Home never showed the Mac's Chief (home.chief.mac)")
    j.sim.tap_el(tile)
    t = time.time()
    while time.time() - t < 30:
        els = j.sim.tree()
        if not j.sim.find(ident="conversation.initialLoading", elements=els) and j.sim.find(ident="conversation.transcript", elements=els):
            return True
        time.sleep(0.5)
    return False


DISCONNECTED = re.compile(r"isn.t connected|Not connected|Connect to your Mac|didn.t answer|Reconnecting|offline", re.I)


def wait_disconnected(sim, timeout=120):
    t = time.time()
    while time.time() - t < timeout:
        hits = [e.label for e in sim.tree() if e.label and DISCONNECTED.search(e.label)]
        if hits:
            return hits[0], time.time() - t
        time.sleep(1.0)
    return None, time.time() - t


def on_info(sim):
    """Chief's info is on screen: its toggles are in the AX tree inside the screen."""
    return any(e.ident in ("chief.settings.hideAlerts", "chief.settings.title") and 0 <= e.frame[0] < 402
               for e in sim.tree())


def open_info(sim):
    # The header's name opens Chief's info (the trailing button is Invite to cmux).
    sim.tap_q(ident="conversation.header.name")
    found = sim.wait(timeout=10, ident="chief.settings")
    time.sleep(1.8)  # the push (or sheet) settles
    return bool(found)


def close_info(sim):
    """Done on the old sheet; the bar's back control on a pushed page (its label is
    the previous page's title, e.g. "Chief" or "Edit", so it is found by place)."""
    done = sim.find(ident="chief.settings.done")
    if done:
        sim.tap_el(done[0])
    else:
        back = [e for e in sim.tree() if e.kind == "Button" and e.frame[1] < 130 and 0 <= e.frame[0] < 70]
        if back:
            sim.tap_el(back[0])
    time.sleep(2.0)


def appearance(udid, mode):
    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", mode], check=True)
    time.sleep(1.0)


def main():  # noqa: C901 - one live scenario
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--sim-name", default="cmux-chiefinfo")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--reuse", action="store_true", help="install over the signed-in app instead of a fresh install")
    ap.add_argument("--out")
    a = ap.parse_args()

    mac_app = os.path.abspath(a.mac_app)
    os.environ.setdefault("CMUX_MOBILE_E2E_ALLOW_OTHER_RIGS", "1")
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "chief-info", a.label)
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
    result = {"label": a.label, "app": a.app, "mac_app": os.path.basename(mac_app), "simulator": f"{a.sim_name} {udid}",
              "messages_reference": MESSAGES, "states": {}, "checks": {}}
    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}), cmux-mobile-host {'running' if mac.wait_hostd(120) else 'NOT running'}")
        j = Journey(sim, mac, out, a.app, log)
        if a.reuse:
            subprocess.run(["xcrun", "simctl", "install", udid, a.app], check=True)
            sim.launch(BUNDLE)
            sim.wait(label="Workspaces", kind="RadioButton", timeout=40)
            steps = j.run(only={"mac_discovered"})
        else:
            steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        log(f"setup: {[(s['id'], s['status']) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            # The connect step's Continue sometimes does not advance (the rig's known
            # onboarding flake, journey.s_choose_space): relaunch and take it again.
            log("setup failed once; relaunching the app and retrying choose_space")
            sim.launch(BUNDLE)
            steps = j.run(only={"choose_space", "mac_discovered"})[-2:]  # run() returns every step so far
            log(f"setup retry: {[(s['id'], s['status']) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            raise RuntimeError(f"setup failed: {steps}")
        appearance(udid, "light")
        loaded = open_chief(j)
        log(f"Chief loaded: {loaded}")
        name = "Chief"
        if not open_info(sim):
            raise RuntimeError("Chief's info never opened")
        # Connected: the engine read settles (model rows), then each appearance.
        sim.wait(timeout=30, ident="chief.settings.harness")

        def capture(state):
            for mode in ("light", "dark"):
                appearance(udid, mode)
                m = measure(sim, name)
                m["shot"] = sim.shot(f"{a.label}-{state}-{mode}")
                result["states"][f"{state}-{mode}"] = m
                log(f"{state}/{mode}: {json.dumps({k: v for k, v in m.items() if k != 'texts'})}")
            appearance(udid, "light")

        capture("connected")
        if sim.find(ident="chief.settings.message"):
            # The controls still act (the new page only).
            hide = sim.find(ident="chief.settings.hideAlerts")
            if hide:
                # The switch itself (a tap on the row's label does not toggle, as in Settings).
                def flip():
                    x, y, w, h = sim.find(ident="chief.settings.hideAlerts")[0].frame
                    # A held press, as the rig's Settings switches (a bare tap can miss a UISwitch).
                    sim.press(x + w - 40, y + h / 2, hold=0.1); time.sleep(1.5)
                before = hide[0].value
                flip()
                after = sim.find(ident="chief.settings.hideAlerts")[0].value
                flip()
                restored = sim.find(ident="chief.settings.hideAlerts")[0].value
                result["checks"]["hide_alerts_toggles"] = {"before": before, "after": after, "restored": restored,
                                                           "pass": before != after and before == restored}
            result["checks"]["model_controls"] = [e.ident for e in sim.tree() if (e.ident or "").split(".")[-1]
                                                  in ("harness", "model", "effort", "lastModel")]
            edit = sim.find(ident="chief.settings.edit")
            if edit:
                sim.tap_el(edit[0]); time.sleep(1.5)
                result["checks"]["edit_opens_name"] = bool(sim.find(ident="chief.settings.name"))
                sim.shot(f"{a.label}-edit")
                close_info(sim)
            # The edge swipe pops back to the conversation.
            sim.drag(2, 450, 330, 450, 0.5, 30, 0.1); time.sleep(1.5)
            result["checks"]["edge_swipe_pops"] = not on_info(sim)
            sim.shot(f"{a.label}-after-swipe")
            if on_info(sim):
                close_info(sim)
                result["checks"]["back_button_pops"] = not on_info(sim)
            open_info(sim)
            sim.tap_q(ident="chief.settings.message"); time.sleep(2.0)
            result["checks"]["message_returns_with_keyboard"] = bool(sim.find(ident="conversation.transcript")) and bool(sim.keyboard())
            sim.shot(f"{a.label}-message")
            j.hide_keyboard()
            open_info(sim)
            log(f"checks: {json.dumps(result['checks'])}")

        # Disconnected: the rig Mac quits with the page open. A graceful
        # terminate can miss an app LaunchServices does not list for this
        # session; then the rig's own app and host get SIGTERM.
        if not mac.quit():
            for pid in mac.main_pids() + mac.hostd_pids():
                os.kill(pid, signal.SIGTERM)
        log(f"rig Mac running after quit: {bool(mac.main_pids())}, host: {bool(mac.hostd_pids())}")
        text, took = wait_disconnected(sim)
        log(f"rig Mac quit; page says {text!r} after {took:.1f} s")
        result["disconnected_after_s"] = round(took, 1)
        time.sleep(2)
        capture("disconnected")
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
