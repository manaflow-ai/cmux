"""Round-8 verifier: Jump to bottom in a fresh Codex tab while Codex streams (prompt sent
from the phone). Even trips: 4 flings, settle 1.5 s, jump; odd trips: 2 flings, jump at once.

    python3 v8v.py v8v_cxjump TAG TRIPS [PROMPT]
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

HERE = os.path.dirname(os.path.abspath(__file__))
PROMPT = ("Print the numbers 1 to 900 in your reply, one per line, as N. followed by a different sentence about "
          "mountains each time. No tools.")


def main():
    tag, trips = sys.argv[1], int(sys.argv[2])
    prompt = sys.argv[3] if len(sys.argv) > 3 else PROMPT
    s, m, j = ctx()
    t0s = time.strftime("%Y-%m-%d %H:%M:%S")
    if prompt != "-":
        tq.paste_composer(prompt)
        time.sleep(1); j.hide_keyboard(); time.sleep(20)
    video = tq.rec_start(tag)
    vt0 = tq.load()["rec"]["t0"]
    taps = []
    for trip in range(trips):
        for _ in range(4 if trip % 2 == 0 else 2):
            s.swipe(200, 250, 200, 650, duration=0.08)
            time.sleep(0.2)
        if trip % 2 == 0:
            time.sleep(1.5)
        jb = v8.jump_button()
        if jb:
            s.tap_el(jb); taps.append(round(time.time() - vt0, 2))
        time.sleep(3)
    tq.rec_stop()
    T1 = time.time()
    lg = open(v8.applog(t0s, os.path.join(v8.V6, f"{tag}.log")), errors="replace").read()
    bj = os.path.join(v8.V6, f"{tag}-black.json")
    subprocess.run([sys.executable, os.path.join(HERE, "v8v_black.py"), video, "--json", bj], capture_output=True)
    b = json.load(open(bj))
    import v8v_fl
    fl = v8v_fl.summary(vt0, T1)
    res = {"tag": tag, "trips": trips, "taps_v": taps, "fling_bottom": len(re.findall(r"a fling reached the bottom", lg)),
           "video_black_runs": [(r["start"], r["dur_ms"]) for r in b["black_runs"]], "video_black_over_1_frame": b["black_runs_over_17ms"],
           "framelog_blank_runs_over_1": [(round(r["t0"] - vt0, 2), r["frames"]) for r in fl["blank_runs"] if r["frames"] > 1],
           "frac_gaps_over_34ms": b["frac_gaps_over_34ms"], "load": v8.loads()}
    json.dump(res, open(os.path.join(v8.V6, f"{tag}-result.json"), "w"), indent=1)
    ev("cxjump", **res)


if __name__ == "__main__":
    main()
