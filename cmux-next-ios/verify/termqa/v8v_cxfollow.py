"""Round-8 verifier: follow real Codex hands-off and compare the phone's last rows with the
Mac's screen (oracle) every GAP seconds. Optional prompt (typed on the phone) and recording.

    python3 v8v.py v8v_cxfollow TAG SECONDS [GAP=45] [PROMPT|-] [REC_SECONDS=0]
"""
import json
import os
import re
import sys
import time

import tq
import v8
from v8 import ev, ctx


def norm(rows):
    return [re.sub(r"[^0-9A-Za-z]", "", r)[:40] for r in rows if r.strip()]


def main():
    tag, secs = sys.argv[1], int(sys.argv[2])
    gap = float(sys.argv[3]) if len(sys.argv) > 3 else 45
    prompt = sys.argv[4] if len(sys.argv) > 4 else "-"
    rec = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    s, m, j = ctx()
    if prompt != "-":
        tq.paste_composer(prompt)
        time.sleep(1); j.hide_keyboard(); time.sleep(3)
    if rec:
        tq.rec_start(tag)
    T = time.time()
    out = []
    while time.time() - T < secs:
        if rec and time.time() - T > rec and tq.load().get("rec"):
            tq.rec_stop()
        p, mm = tq.compare_bottom(6)
        mi_p, mi_m = tq.max_item("\n".join(p)), tq.max_item("\n".join(mm))
        same = norm(p)[-3:] == norm(mm)[-3:]
        r = {"t": round(time.time() - T, 1), "phone_max_item": mi_p, "mac_max_item": mi_m, "tail_equal": same, "phone": p, "mac": mm}
        out.append(r)
        ev("cxfollow", tag=tag, **r)
        time.sleep(gap)
    if tq.load().get("rec"):
        tq.rec_stop()
    with open(os.path.join(v8.V6, f"{tag}-compare.jsonl"), "a") as f:
        for r in out:
            f.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
