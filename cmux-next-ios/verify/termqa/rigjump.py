"""Jump to bottom from deep history while output streams, on the rig (V5-1, T-SCROLL-09).

    python3 rigjump.py TAG [--trips 4] [--flings 14] [--no-loop]

Types the slow GEN loop on the phone (unless --no-loop), then per trip: flings up
--flings times, waits for the page to settle, taps Scroll to bottom, and waits. The
whole run is recorded; motion.py reports black frames and flashes at 60 fps, and the
log lines for the jumps are kept in artifacts/<TAG>.log.
"""
import argparse
import json
import os
import subprocess
import sys
import time

from tq import ART, HERE, composer_send, ctx, hide_kb, rec_start, rec_stop


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--trips", type=int, default=4)
    ap.add_argument("--flings", type=int, default=14)
    ap.add_argument("--no-loop", action="store_true")
    a = ap.parse_args()
    s, _, _ = ctx()
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    if not a.no_loop:
        composer_send("for i in $(seq 1 6000); do echo GEN-$i; sleep 0.01; done")
    hide_kb()  # swipes that end on the keyboard hang axe
    video = rec_start(a.tag)
    taps = []
    for _ in range(a.trips):
        for _ in range(a.flings):
            s.swipe(200, 250, 200, 650, duration=0.12)
            time.sleep(0.35)
        time.sleep(2.5)  # the last fling settles
        taps.append(time.time())
        s.tap_q(label="Scroll to bottom", timeout=5)
        time.sleep(2.5)  # the jump lands and follows
    t_start = json.load(open(os.path.expanduser("~/cmux-next-ios-e2e/termqa-state.json")))["rec"]["t0"]
    rec_stop()
    with open(os.path.join(ART, f"{a.tag}.log"), "w") as f:
        subprocess.run(["xcrun", "simctl", "spawn", s.udid, "log", "show", "--start", t0, "--style", "compact",
                        "--predicate", 'subsystem == "dev.cmux.mobile" AND category == "terminal-sizing"'],
                       stdout=f, stderr=subprocess.DEVNULL)
    out = os.path.join(ART, f"{a.tag}-motion.json")
    subprocess.run([sys.executable, os.path.join(HERE, "motion.py"), video, "--fps", "60", "--bottom", "0.8",
                    "--quiet", "--json", out], capture_output=True)
    summary = json.load(open(out))["summary"]
    rel = [round(t - t_start, 2) for t in taps]
    print(json.dumps({"video": video, "taps_s": rel, "black_frames": summary.get("black_frames"),
                      "black_times": summary.get("black_times"), "flashes": summary.get("flash_list"),
                      "valid": summary.get("valid")}))


if __name__ == "__main__":
    main()
