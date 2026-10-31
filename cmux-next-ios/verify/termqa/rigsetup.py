"""Set up one rig instance (simulator + the hidden tagged Mac app on a mini), selected by
TQ_STATE / TQ_HOST / TQ_RBASE (see tq.py). Fresh install, sign-in with the DEBUG dev
credential, the real onboarding (team step, Connect your Mac, notifications), the Mac
listed and linked, then the seed workspace (two terminal tabs) made on the Mac.

    python3 rigsetup.py [--keep-install] [--rec NAME] [--immediate] [--d6-only]

--rec records the onboarding (D6: every Continue tap is logged with the time and
whether the page advanced) to TQ_RAW/NAME.mp4. --immediate taps Continue the moment the
page is in the tree (D6's fast tap); --d6-only stops after the probe (no link, no seed). Writes seed/ws_name/device_id into
the state file.
"""
import json
import os
import sys
import time

import tq
from tq import ctx, load, save, log


def continue_probe(sim, immediate=False):
    """D6: tap Continue on 'Connect your Mac' once the button is still (or, with
    `immediate`, the moment it is in the tree, mid-push included), then watch the
    page for 4 s; log each tap and whether the page left. Up to 4 taps."""
    taps = []
    for attempt in range(4):
        prev = button = None
        for _ in range(160 if immediate else 40):
            found = sim.find(label="Continue", kind="Button")
            button = found[0] if found else None
            if button and (immediate or (prev and button.frame == prev)):
                break
            prev = button.frame if button else None
            time.sleep(0.05 if immediate else 0.25)
        if not button:
            break
        t = sim.tap_el(button)
        left = None
        while time.time() - t < 4:
            if not sim.find(contains="Connect your Mac"):
                left = round(time.time() - t, 2)
                break
            time.sleep(0.2)
        taps.append({"t": round(t, 3), "frame": list(button.frame), "left_after_s": left, "immediate": immediate})
        log(f"D6 Continue tap {attempt + 1}: {'advanced in %.2f s' % left if left is not None else 'did NOT advance in 4 s'}")
        if left is not None:
            break
    return taps


IMMEDIATE = "--immediate" in sys.argv
ONLY_D6 = "--d6-only" in sys.argv


def main():
    keep = "--keep-install" in sys.argv
    rec = sys.argv[sys.argv.index("--rec") + 1] if "--rec" in sys.argv else None
    sim, mac, j = ctx()
    st = load()
    if rec:
        sim.record_start(os.path.join(tq.RAW, f"{rec}.mp4"))
    out = {}
    if not keep:
        out["fresh_install"] = j.s_fresh_install()
        out["sign_in"] = j.s_sign_in()
    i, _ = sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                         dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=30)
    if i in (0, 1):
        personal = sim.find(ident="setup.teams.personal") or sim.find(label="Not now", kind="Button")
        sim.tap_el(personal[0])
        sim.wait_any([dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=20)
    if IMMEDIATE and sim.wait(contains="Connect your Mac", timeout=10):
        out["d6_taps"] = continue_probe(sim, immediate=True)
    elif sim.find(contains="Connect your Mac"):
        status = sim.wait(ident="connect-mac.status", timeout=30)
        out["connect_status"] = status.label if status else None
        out["d6_taps"] = continue_probe(sim)
    if ONLY_D6:
        if rec:
            sim.record_stop()
        print(json.dumps(out, indent=1, default=str))
        return
    if sim.wait(label="Turn on notifications", timeout=3):
        sim.tap_q(label="Not now", kind="Button")
    if rec:
        sim.record_stop()
    j.seed_mac()
    out["seed"] = j.seed
    out["mac_discovered"] = j.s_mac_discovered()
    st.update({"seed": j.seed, "ws_name": j.ws_name, "device_id": j.device_id, "term": j.seed["term1"]})
    save(st)
    print(json.dumps(out, indent=1, default=str))


if __name__ == "__main__":
    main()
