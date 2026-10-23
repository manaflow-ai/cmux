#!/usr/bin/env python3
"""Real-usage checks of a streamed simulator surface (verify/simulator-surface.md),
after `browser-track-bench.py --surface --keep`: the phone simulator shows the
Mac's phone tab of the rig simulator, which runs Safari on the bench page.

Each check acts on the phone simulator only (axe, posted to that simulator; no
focus anywhere) and reads the result from the rig simulator's own screen
(simctl screenshot + OCR), so it proves the input crossed the real link:

- type:   tap Safari's address bar in the stream, open the phone keyboard from
          the accessory bar, type a word: the rig Safari's address field shows it.
- home:   the accessory bar's Home: the rig simulator shows its home screen.
- settings: from the rig home screen, open Settings by tapping its icon in the
          stream, then scroll Settings by a swipe in the stream.
- kill:   kill the rig's cmux-mobile-host; the app restarts it and the phone's
          stream comes back (overlay fps again) with no action on the phone.
- switch: relaunch the phone app on the other transport; the stream comes back.

usage: surface-checks.py --phone UDID --rig UDID --mac-bundle ID --out DIR [checks...]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))

from journey import BUNDLE  # noqa: E402
from sim import Sim  # noqa: E402


def wait_text(sim, pattern, timeout):
    """Seconds until OCR of `sim` matches `pattern` (None on timeout), and the text."""
    t0 = time.time()
    text = ""
    while time.time() - t0 < timeout:
        text = " ".join(o[4] for o in sim.ocr())
        if re.search(pattern, text, re.I):
            return round(time.time() - t0, 2), text
        time.sleep(0.5)
    return None, text


def hostd_pids(bundle):
    out = subprocess.run(["pgrep", "-f", f"{bundle}.*Contents/Resources/bin/cmux-mobile-host"],
                         capture_output=True, text=True).stdout
    pids = [int(p) for p in out.split()]
    if not pids:
        out = subprocess.run(["pgrep", "-f", "Contents/Resources/bin/cmux-mobile-host"], capture_output=True, text=True).stdout
        for p in out.split():
            cmd = subprocess.run(["ps", "-o", "command=", "-p", p], capture_output=True, text=True).stdout
            if bundle.split(".")[-1] in cmd:
                pids.append(int(p))
    return pids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phone", required=True)
    ap.add_argument("--rig", required=True)
    ap.add_argument("--mac-bundle", required=True, help="the rig app's tag (for its cmux-mobile-host)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--transport", default="wireguard", help="the phone app's transport now")
    ap.add_argument("checks", nargs="*", default=["type", "home", "settings", "kill", "switch"])
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    phone = Sim(a.phone, os.path.join(a.out, "shots"))
    rig = Sim(a.rig, os.path.join(a.out, "rig-shots"))
    results = {}

    def log(msg):
        print(time.strftime("%H:%M:%S"), msg, flush=True)

    def record(name, ok, **facts):
        results[name] = {"ok": ok, **facts}
        log(f"{'PASS' if ok else 'FAIL'} {name} {json.dumps(facts)[:300]}")
        phone.shot(f"{name}-phone")
        rig.shot(f"{name}-rig")
        json.dump(results, open(os.path.join(a.out, "checks.json"), "w"), indent=2)

    video = phone.record_start(os.path.join(a.out, "checks.mp4"))
    log(f"recording the phone from {video:.3f}")
    try:
        for check in a.checks:
            if check == "type":
                # Safari's address bar sits at the bottom of the rig simulator's screen;
                # the stream shows that screen aspect fit inside the phone's page.
                phone.tap(201, 640)
                time.sleep(1.5)
                kb = phone.find(ident="simulator.keyboard")
                if kb:
                    phone.tap_el(kb[0])
                    time.sleep(1.0)
                word = "cmuxsurface"
                phone.softtype(word)
                took, text = wait_text(rig, word, 15)
                record("type", took is not None, seconds=took, rig_text=text[:160])
                # Leave the field: Escape is on the phone's keys only as text; tap Cancel in the stream.
                phone.softtype("\n")
                time.sleep(2)
            elif check == "home":
                home = phone.find(ident="simulator.home")
                if home:
                    phone.tap_el(home[0])
                took, text = wait_text(rig, r"Settings|Safari|Photos|Calendar", 15)
                record("home", bool(home) and took is not None, seconds=took, rig_text=text[:160])
            elif check == "settings":
                # Find the Settings icon on the rig's home screen, then tap the same spot in the stream.
                hits = [o for o in rig.ocr() if o[4].strip() == "Settings"]
                stream = phone.find(ident="simulator.screen")
                if not hits or not stream:
                    record("settings", False, why="no Settings icon or no stream view")
                    continue
                x, y, w, h, _ = hits[0]
                fx, fy, fw, fh = stream[0].frame
                # The rig screen is drawn aspect fit in the stream view (402 x 874 points).
                scale = min(fw / 402, fh / 874)
                ox = fx + (fw - 402 * scale) / 2
                oy = fy + (fh - 874 * scale) / 2
                phone.tap(ox + (x + w / 2) * scale, oy + (y - 30) * scale)
                took, text = wait_text(rig, r"General|Accessibility|Privacy", 15)
                before = text
                phone.swipe(ox + 200 * scale, oy + 700 * scale, ox + 200 * scale, oy + 250 * scale, duration=0.4)
                time.sleep(2)
                after = " ".join(o[4] for o in rig.ocr())
                record("settings", took is not None and after != before, open_seconds=took,
                       scrolled=after != before, before=before[:120], after=after[:120])
            elif check == "kill":
                pids = hostd_pids(a.mac_bundle)
                if not pids:
                    record("kill", False, why="no cmux-mobile-host")
                    continue
                t0 = time.time()
                subprocess.run(["kill", "-9", str(pids[0])])
                # The app's supervisor restarts hostd (1 s backoff); the phone redials.
                took, text = wait_text(phone, r"\b[1-9]\d* fps", 90)
                new = hostd_pids(a.mac_bundle)
                record("kill", took is not None and bool(new) and new[0] != pids[0], recovered_seconds=took,
                       old_hostd=pids[0], new_hostd=new[:1], overlay=text[-160:])
            elif check == "switch":
                other = "webrtc" if a.transport == "wireguard" else "wireguard"
                phone.launch(BUNDLE, args=["-cmuxMobile.settings.transport", other])
                time.sleep(4)
                took, text = wait_text(phone, r"\b[1-9]\d* fps", 60)
                record("switch", took is not None, to=other, recovered_seconds=took, overlay=text[-160:])
    finally:
        phone.record_stop()
    json.dump(results, open(os.path.join(a.out, "checks.json"), "w"), indent=2)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
