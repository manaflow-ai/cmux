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


CLOCK = re.compile(r"mac\s+(\d{2})[.:,](\d{2})[.,:](\d{3})")


def wait_fresh(sim, after, timeout):
    """Seconds until the streamed page's clock (the rig Safari's "mac MM:SS.mmm",
    this host's clock) shows a time at least 1 s after `after`: a new frame that
    crossed the link after the fault, not a frozen one. None on timeout."""
    t0 = time.time()
    want = int((after + 1.0) * 1000) % 3_600_000
    text = ""
    while time.time() - t0 < timeout:
        text = " ".join(o[4] for o in sim.ocr())
        m = CLOCK.search(text)
        if m:
            shown = (int(m.group(1)) * 60 + int(m.group(2))) * 1000 + int(m.group(3))
            if 0 <= (shown - want) % 3_600_000 < 600_000:
                return round(time.time() - after, 2), text
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
    ap.add_argument("--page", default="http://127.0.0.1:8791/bench.html?scroll=6", help="the rig's clock page")
    ap.add_argument("checks", nargs="*", default=["home", "settings", "type", "clock", "kill", "switch"])
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

    def stream_map():
        """(x, y, scale) of the rig's 402 x 874 pt screen, drawn aspect fit in the stream view."""
        stream = phone.find(ident="simulator.screen") or [e for e in phone.tree()
                                                          if e.kind == "TextArea" and e.frame[3] > 400]
        fx, fy, fw, fh = stream[0].frame
        scale = min(fw / 402, fh / 874)
        return fx + (fw - 402 * scale) / 2, fy + (fh - 874 * scale) / 2, scale

    def tap_rig_text(label, dy=0.0):
        """Taps, in the stream on the phone, where `label` shows on the rig's own screen."""
        hits = [o for o in rig.ocr() if o[4].strip() == label or o[4].strip().endswith(" " + label)]
        if not hits:
            return False
        x, y, w, h, text = hits[-1]
        if text.strip() != label:
            # OCR joined the label to text before it on the same line: the label is its right end.
            share = len(label) / max(1, len(text.strip()))
            x, w = x + w * (1 - share), w * share
        ox, oy, scale = stream_map()
        phone.tap(ox + (x + w / 2) * scale, oy + (y + h / 2 + dy) * scale)
        return True

    video = phone.record_start(os.path.join(a.out, "checks.mp4"))
    log(f"recording the phone from {video:.3f}")
    try:
        for check in a.checks:
            if check == "type":
                # A page with one text field (bench-page/input.html): tap the field in the
                # stream, open the phone keyboard from the accessory bar, and type.
                subprocess.run(["xcrun", "simctl", "openurl", a.rig, a.page.rsplit("/", 1)[0] + "/input.html"], check=False)
                if wait_text(rig, r"Type here", 15)[0] is None or not tap_rig_text("Type here"):
                    record("type", False, why="no text field on the rig's screen")
                    continue
                time.sleep(1.5)
                kb = phone.find(ident="simulator.keyboard") or phone.find(label="Keyboard", kind="Button")
                if kb:
                    phone.tap_el(kb[0])
                    time.sleep(1.0)
                word = "cmuxsurface"
                phone.softtype(word)
                took, text = wait_text(rig, word, 15)
                record("type", took is not None, seconds=took, rig_text=text[:160])
            elif check == "home":
                home = phone.find(ident="simulator.home") or phone.find(label="Home", kind="Button")
                if home:
                    phone.tap_el(home[0])
                took, text = wait_text(rig, r"Settings|Safari|Photos|Calendar", 15)
                record("home", bool(home) and took is not None, seconds=took, rig_text=text[:160])
            elif check == "settings":
                # Find the Settings icon on the rig's home screen, then tap the same spot in the stream.
                hits = [o for o in rig.ocr() if o[4].strip() == "Settings"]
                # The stream view: the page's large area (its identifier is the container's in AX).
                stream = phone.find(ident="simulator.screen") or [e for e in phone.tree()
                                                                  if e.kind == "TextArea" and e.frame[3] > 400]
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
            elif check == "clock":
                # The bench page (the streamed clock) back on the rig, for kill and switch.
                subprocess.run(["xcrun", "simctl", "openurl", a.rig, a.page], check=False)
                took, text = wait_text(phone, r"mac\s+\d{2}[.:,]\d{2}", 30)
                record("clock", took is not None, seconds=took)
            elif check == "kill":
                pids = hostd_pids(a.mac_bundle)
                if not pids:
                    record("kill", False, why="no cmux-mobile-host")
                    continue
                t0 = time.time()
                subprocess.run(["kill", "-9", str(pids[0])])
                # The app's supervisor restarts hostd (1 s backoff); the phone redials.
                took, text = wait_fresh(phone, t0, 90)
                new = hostd_pids(a.mac_bundle)
                record("kill", took is not None and bool(new) and new[0] != pids[0], recovered_seconds=took,
                       old_hostd=pids[0], new_hostd=new[:1], overlay=text[-160:])
            elif check == "switch":
                other = "webrtc" if a.transport == "wireguard" else "wireguard"
                t0 = phone.launch(BUNDLE, args=["-cmuxMobile.settings.transport", other])
                # The relaunched app opens on its last tab, the simulator tab.
                took, text = wait_fresh(phone, t0, 60)
                record("switch", took is not None, to=other, recovered_seconds=took, overlay=text[-160:])
    finally:
        phone.record_stop()
    json.dump(results, open(os.path.join(a.out, "checks.json"), "w"), indent=2)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
