"""T-TABS-01 inactive card after a relaunch: in e2e-t1 type (on the phone)
`sleep D; seq 1 60; echo CARD-AFTER-<n>`, switch to e2e-t2, terminate the app, wait for the
Mac's t1 to print the marker, relaunch, open the grid first and read the t1 card.

    TQ_BUNDLE=... python3 q11.py q11_card TAG [D=15]
"""
import os
import sys
import time

import reg
import tq
import v8


def to_tab(s, prefix):
    c = [e for e in s.find(kind="Button") if (e.label or "").startswith(prefix + ", tab")]
    if c:  # in the grid: tap the card
        s.tap_el(c[0]); time.sleep(3)
    else:
        reg.open_tab(s, prefix)


def main():
    tag = sys.argv[1]
    d = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    s, m, j = tq.ctx()
    n = int(time.time()) % 100000
    to_tab(s, "e2e-t1")
    tq.paste_composer(f"clear; sleep {d}; seq 1 60; echo CARD-AFTER-{n}")
    time.sleep(1); j.hide_keyboard()
    to_tab(s, "e2e-t2"); time.sleep(2)
    s.terminate(tq.BUNDLE)
    t1 = tq.load()["seed"]["term1"]
    t = time.time()
    while time.time() - t < d + 30 and f"CARD-AFTER-{n}" not in tq.mac_screen(t1):
        time.sleep(1)
    mac_has = f"CARD-AFTER-{n}" in tq.mac_screen(t1)
    s.launch(tq.BUNDLE, args=["-CmuxMobileFrameLog", "YES"])
    s.wait(label="Tabs", kind="Button", timeout=40)
    s.tap_q(label="Tabs", kind="Button")
    shots, seen = [], None
    t0 = time.time()
    for k in range(12):
        shots.append(v8.shot(f"{tag}-grid-{k}"))
        txt = " ".join(x[4] for x in s.ocr() if x[0] < 201 and 110 < x[1] < 400)
        if f"CARD-AFTER-{n}" in txt or f"AFTER-{n}" in txt:
            seen = round(time.time() - t0, 2)
            break
        time.sleep(0.5)
    return v8.ev("card", tag=tag, marker=f"CARD-AFTER-{n}", mac_has=mac_has, t1_card_marker_after_s=seen, shots=[os.path.basename(x) for x in shots])


if __name__ == "__main__":
    main()
