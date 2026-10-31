"""Round 8 (V6-3 re-check): Jump to bottom from deep history and mid-fling while a GEN
loop typed on the phone streams at the cap. motion.py black runs plus `blank page` lines.

    python3 v8_jump.py TAG [TRIPS=10] [TAB=e2e-t2]
"""
import json
import os
import re
import subprocess
import sys
import time

import tq
import v8
from v8 import ev, ctx
from v8_hold import open_tab


def main():
    tag = sys.argv[1]
    trips = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    tab = sys.argv[3] if len(sys.argv) > 3 else "e2e-t2"
    s, m, j = ctx()
    open_tab(s, tab)
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    tq.paste_composer("for i in $(seq 1 60000); do echo GEN-$i; sleep 0.01; done")
    time.sleep(1); j.hide_keyboard(); time.sleep(3)
    video = tq.rec_start(tag)
    taps = []
    for trip in range(trips):
        for _ in range(6 if trip % 2 == 0 else 2):
            s.swipe(200, 250, 200, 750, duration=0.08)
            time.sleep(0.2)
        if trip % 2 == 0:
            time.sleep(1.5)  # settled deep in history
        jb = v8.jump_button()
        if jb:
            s.tap_el(jb); taps.append(round(time.time() - tq.load()["rec"]["t0"], 2))
        time.sleep(3)
    tq.rec_stop()
    v8.interrupt()
    lg = open(v8.applog(t0, os.path.join(v8.V6, f"{tag}.log"))).read()
    out = os.path.join(v8.V6, f"{tag}-motion.json")
    subprocess.run([sys.executable, os.path.join(tq.HERE, "motion.py"), video, "--fps", "30", "--bottom", "0.8", "--quiet", "--json", out],
                   capture_output=True)
    su = json.load(open(out))["summary"]
    res = {"tag": tag, "trips": trips, "taps_v": taps,
           "blank_page_lines": re.findall(r"blank page:[^\n]*", lg)[:20],
           "fling_bottom": len(re.findall(r"a fling reached the bottom", lg)),
           "black_runs": [(r["start"], r["end"]) for r in su["black_runs"]],
           "valid": su["source"]["valid"], "load": v8.loads()}
    json.dump(res, open(os.path.join(v8.V6, f"{tag}-result.json"), "w"), indent=1)
    ev("jump", **{k: v for k, v in res.items() if k != "blank_page_lines"})
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
