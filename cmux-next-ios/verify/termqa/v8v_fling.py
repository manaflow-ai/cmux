"""Round-8 verifier, V5-2: flings toward older history from the live bottom during fast
output at the cap. A fling that ends at following (no Jump to bottom button 0.5 s after
it) or a `a fling reached the bottom` line is a snap. GEN typed on the phone.

    python3 v8v.py v8v_fling TAG [N=80] [TAB=e2e-t2]
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

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    tag = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 80
    tab = sys.argv[3] if len(sys.argv) > 3 else "e2e-t2"
    s, m, j = ctx()
    if not s.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    open_tab(s, tab)
    t0s = time.strftime("%Y-%m-%d %H:%M:%S")
    tq.paste_composer("for i in $(seq 1 200000); do echo GEN-$i; sleep 0.004; done")
    time.sleep(1); j.hide_keyboard(); time.sleep(3)
    video = tq.rec_start(tag)
    vt0 = tq.load()["rec"]["t0"]
    flings, snaps, taps = [], [], []
    for i in range(n):
        s.swipe(200, 300, 200, 650, duration=0.1)
        tf = time.time() - vt0
        time.sleep(0.5)
        jb = v8.jump_button()
        flings.append(round(tf, 2))
        if not jb:
            snaps.append(round(tf, 2))
            continue
        taps.append(round(time.time() - vt0, 2))
        s.tap_el(jb)
        time.sleep(0.9)
    tq.rec_stop()
    T1 = time.time()
    v8.interrupt()
    lg = open(v8.applog(t0s, os.path.join(v8.V6, f"{tag}.log")), errors="replace").read()
    bj = os.path.join(v8.V6, f"{tag}-black.json")
    subprocess.run([sys.executable, os.path.join(HERE, "v8v_black.py"), video, "--json", bj], capture_output=True)
    b = json.load(open(bj))
    import v8v_prunes
    pr = v8v_prunes.prunes(os.path.join(v8.V6, f"{tag}.log"))
    res = {"tag": tag, "flings": len(flings), "fling_times_v": flings, "jump_taps_v": taps, "no_jump_button_after_fling": snaps,
           "fling_reached_bottom_lines": re.findall(r"[0-9:.]{12} [^\n]*a fling reached the bottom[^\n]*", lg),
           "prunes": len(pr) + len(re.findall(r"history pruned", lg)), "history_pruned_while_reading": len(re.findall(r"history pruned", lg)),
           "video_black_runs": [(r["start"], r["dur_ms"]) for r in b["black_runs"]], "video_black_over_1_frame": b["black_runs_over_17ms"],
           "load": v8.loads()}
    json.dump(res, open(os.path.join(v8.V6, f"{tag}-result.json"), "w"), indent=1)
    ev("fling", **{k: v for k, v in res.items() if k not in ("fling_times_v", "jump_taps_v")})


if __name__ == "__main__":
    main()
