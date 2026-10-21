"""Round-8 verifier drops with output arriving (T-LIFE-08/09, V6-4, V2-3 at the cap).
Every command is typed on the phone; the Mac side only kills the rig's hostd.

    python3 v8v.py v8v_drop TAG MODE [TAB=e2e-t2]
MODE: read1 | read2 (two kills GAP s apart) | follow1 | follow2 | fling2 (two kills, then a fling right away)
A GEN loop typed on the phone streams through the whole run.
"""
import json
import os
import re
import subprocess
import sys
import time

import tq
import v8
from v8 import ev, ctx, ids, ocr_rows
from v8_hold import open_tab

HERE = os.path.dirname(os.path.abspath(__file__))


def top_ids():
    r = ids(ocr_rows(60, 400))
    return r[:6]


def main():
    tag, mode = sys.argv[1], sys.argv[2]
    tab = sys.argv[3] if len(sys.argv) > 3 else "e2e-t2"
    gap = float(os.environ.get("GAP", "3.4"))
    s, m, j = ctx()
    if not s.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    open_tab(s, tab)
    t0s = time.strftime("%Y-%m-%d %H:%M:%S")
    T0 = time.time()
    tq.paste_composer("for i in $(seq 1 60000); do echo GEN-$i; sleep 0.01; done")
    time.sleep(1); j.hide_keyboard(); time.sleep(4)
    if mode.startswith("read") or mode.startswith("fling"):
        for _ in range(5):
            s.swipe(200, 250, 200, 750, duration=0.08)
            time.sleep(0.25)
        time.sleep(3)
    video = tq.rec_start(tag)
    vt0 = tq.load()["rec"]["t0"]
    time.sleep(1.5)
    before = top_ids()
    time.sleep(1.0)
    before2 = top_ids()
    kills = [v8.kill_hostd()]
    if mode.endswith("2"):
        time.sleep(gap)  # intentional spacing between the two injected faults
        kills.append(v8.kill_hostd())
    if mode == "fling2":
        time.sleep(0.3)
        s.swipe(200, 250, 200, 650, duration=0.1)
    time.sleep(12)  # reconnect plus replay, then observe
    after = top_ids()
    time.sleep(3)
    after2 = top_ids()
    jb = bool(v8.jump_button())
    v8.shot(f"{tag}-after")
    tq.rec_stop()
    T1 = time.time()
    v8.interrupt()
    logp = v8.applog(t0s, os.path.join(v8.V6, f"{tag}.log"))
    lg = open(logp, errors="replace").read()
    bj = os.path.join(v8.V6, f"{tag}-black.json")
    subprocess.run([sys.executable, os.path.join(HERE, "v8v_black.py"), video, "--json", bj], capture_output=True)
    b = json.load(open(bj))
    import v8v_fl
    fl = v8v_fl.summary(vt0, T1)
    json.dump(fl, open(os.path.join(v8.V6, f"{tag}-framelog.json"), "w"), indent=1)
    res = {"tag": tag, "mode": mode, "gap": gap, "kills_v": [round(k - vt0, 2) for k in kills],
           "hostd": v8.hostd_events(kills[0] - 0.5), "before": before, "before_plus1s": before2,
           "after": after, "after_plus3s": after2, "jump_visible_after": jb,
           "replays": re.findall(r"surface \d+: mirror reset cause=\S+", lg),
           "unknown_surface": lg.count("unknown surface"),
           "reading_marks": re.findall(r"(?:reading mark|restored row)[^\n]*", lg)[:12],
           "blank_page_lines": re.findall(r"blank page:[^\n]*", lg)[:12],
           "video_black_runs": [(r["start"], r["dur_ms"]) for r in b["black_runs"]],
           "video_black_over_1_frame": b["black_runs_over_17ms"],
           "framelog_blank_runs_over_1": [(round(r["t0"] - vt0, 2), r["frames"]) for r in fl["blank_runs"] if r["frames"] > 1],
           "framelog_blank_frames": fl["blank_frames"], "dt_max": fl["dt_max"],
           "frac_gaps_over_34ms": b["frac_gaps_over_34ms"], "load": v8.loads()}
    json.dump(res, open(os.path.join(v8.V6, f"{tag}-result.json"), "w"), indent=1)
    ev("drop", **{k: v for k, v in res.items() if k not in ("reading_marks", "hostd", "blank_page_lines")})
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
