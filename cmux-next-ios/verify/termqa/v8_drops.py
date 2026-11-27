"""VERIFY-round6 drops (T-LIFE-08/09/12, V3-3): every command typed on the phone.

    python3 v6_drops.py TAG twoquick|midfling|follow

twoquick: reading near the top of history, two hostd kills 3.4 s apart (VERIFY-round5 s4).
midfling: a fling toward older history with the kill sent at the same moment (s3).
follow:   following at the live bottom during the GEN loop, one kill.
Records the run; OCR of the top rows before and +12 s after; hostd starting/link-up times;
replay and unknown-surface counts from the app log; motion.py black runs.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time

import tq
import v8 as v6
from v8 import ev, ctx, ids, ocr_rows


def main():
    tag, mode = sys.argv[1], sys.argv[2]
    s, m, j = ctx()
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    j.hide_keyboard()
    if mode == "twoquick":
        for _ in range(30):  # toward the top of history
            s.swipe(200, 200, 200, 750, duration=0.08)
            time.sleep(0.25)
        time.sleep(3)
    elif mode == "midfling":
        for _ in range(3):
            s.swipe(200, 250, 200, 650, duration=0.12)
            time.sleep(0.35)
        time.sleep(3)
    video = tq.rec_start(tag)
    vt0 = json.load(open(os.path.expanduser("~/cmux-next-ios-e2e/termqa-state.json")))["rec"]["t0"]
    time.sleep(1)
    before = ids(ocr_rows(60, 520))[:6]
    before_txt = [t for _, t in ocr_rows(60, 200)][:4]
    kills = []
    if mode == "midfling":
        th = threading.Thread(target=lambda: s.swipe(200, 250, 200, 650, duration=0.12))
        th.start()
        kills.append(v6.kill_hostd())
        th.join()
    else:
        kills.append(v6.kill_hostd())
        if mode == "twoquick":
            time.sleep(3.4)  # intentional spacing between the two injected faults
            kills.append(v6.kill_hostd())
    time.sleep(12)  # reconnect plus replay, then observe
    after = ids(ocr_rows(60, 520))[:6]
    after_txt = [t for _, t in ocr_rows(60, 200)][:4]
    jb = bool(v6.jump_button())
    tq.rec_stop()
    v6.applog(t0, os.path.join(v6.V6, f"{tag}.log"))
    lg = open(os.path.join(v6.V6, f"{tag}.log")).read()
    out = os.path.join(v6.V6, f"{tag}-motion.json")
    subprocess.run([sys.executable, os.path.join(tq.HERE, "motion.py"), video, "--fps", "30", "--bottom", "0.8", "--quiet", "--json", out],
                   capture_output=True)
    d = json.load(open(out))
    su = d["summary"]
    json.dump({"summary": su, "frames_black_or_flash": [f for f in d["frames"] if f.get("black") or f.get("flash")]}, open(out, "w"))
    res = {"tag": tag, "mode": mode, "kills_v": [round(k - vt0, 2) for k in kills],
           "hostd": v6.hostd_events(kills[0] - 0.5), "before": before or before_txt, "after": after or after_txt,
           "jump_visible_after": jb,
           "replays": re.findall(r"surface \d+: mirror reset cause=\S+", lg),
           "unknown_surface": lg.count("unknown surface"),
           "reading_marks": re.findall(r"reading mark[^\n]*", lg),
           "black_runs": [(r["start"], r["end"]) for r in su["black_runs"]],
           "flashes_foreign": su.get("flashes_foreign"), "valid_fps": su["source"]["valid"]}
    json.dump(res, open(os.path.join(v6.V6, f"{tag}-result.json"), "w"), indent=1)
    ev("drops", **{k: v for k, v in res.items() if k != "reading_marks"})
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
