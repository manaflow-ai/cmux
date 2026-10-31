"""VERIFY-round5 V2-3 eviction repro on the rig (every command typed on the phone).

    python3 evict.py TAG [--fill] [--flings 12] [--drop]

--fill: types a 30000-row HIST loop in the open tab first (history to the cap).
Then types the slow GEN loop, flings up, settles, OCRs the top rows, kills the rig's
cmux-mobile-host (only the rig's, by its app path), waits for the reattach, OCRs again and
prints both. Logs: `artifacts/<TAG>.log` (the app's terminal/sizing log for the run).
"""
import argparse
import re
import subprocess
import time

from tq import ART, HOST, composer_send, ctx, hide_kb, log
import os

RIG_HOSTD = "cmux-mobile-e2e-604fc689.app/Contents/Resources/bin/cmux-mobile-host"


def top_rows(s, n=6):
    rows = [(y, t) for x, y, w, h, t in s.ocr() if 60 <= y <= 520]
    rows.sort()
    return [t for _, t in rows[:n]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--fill", action="store_true")
    ap.add_argument("--flings", type=int, default=12)
    ap.add_argument("--drop", action="store_true")
    a = ap.parse_args()
    s, _, j = ctx()
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    if a.fill:
        composer_send("for i in $(seq 100001 130000); do echo HIST-$i; done")
        time.sleep(8)  # stimulus pacing: the fill streams
    composer_send("for i in $(seq 1 4000); do echo GEN-$i; sleep 0.01; done")
    hide_kb()
    time.sleep(2)  # stimulus pacing: the loop streams
    for _ in range(a.flings):
        s.swipe(200, 250, 200, 650, duration=0.12)
        time.sleep(0.35)
    time.sleep(3)  # the last fling settles
    before = top_rows(s)
    log(f"evict {a.tag}: before {before}")
    after = None
    if a.drop:
        subprocess.run(["ssh", HOST, f"pkill -9 -f '{RIG_HOSTD}'"])
        time.sleep(9)  # reconnect (about 2.4 s) plus the replay
        after = top_rows(s)
        log(f"evict {a.tag}: after {after}")
    out = os.path.join(ART, f"{a.tag}.log")
    with open(out, "w") as f:
        subprocess.run(["xcrun", "simctl", "spawn", s.udid, "log", "show", "--start", t0, "--style", "compact",
                        "--predicate", 'subsystem == "dev.cmux.mobile" AND (category == "terminal-sizing" OR category == "terminal" OR category == "link")'],
                       stdout=f, stderr=subprocess.DEVNULL)
    hist = lambda rows: [m.group(0) for r in rows for m in [re.search(r"(HIST|GEN)-\d+", r)] if m]
    print({"before": hist(before), "after": hist(after or [])})
    print(out)


if __name__ == "__main__":
    main()
