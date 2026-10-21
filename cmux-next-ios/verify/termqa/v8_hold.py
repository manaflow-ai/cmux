"""Round 8 (V6-2 re-check): following at the history cap, hands off, while a GEN loop
typed on the phone streams. Records, then motion.py black runs plus the app's
`history pruned` and `blank page` lines.

    python3 v8_hold.py TAG [SECONDS=90] [TAB=e2e-t2]
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


def open_tab(s, prefix):
    s.tap_q(label="Tabs", kind="Button"); time.sleep(2.5)
    c = [e for e in s.find(kind="Button") if (e.label or "").startswith(prefix)]
    if not c:
        raise SystemExit(f"no card {prefix}: {[e.label for e in s.find(kind='Button')]}")
    s.tap_el(c[0]); time.sleep(3)


def main():
    tag = sys.argv[1]
    seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 90
    tab = sys.argv[3] if len(sys.argv) > 3 else "e2e-t2"
    s, m, j = ctx()
    open_tab(s, tab)
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    tq.paste_composer("for i in $(seq 1 60000); do echo GEN-$i; sleep 0.01; done")
    time.sleep(1); j.hide_keyboard(); time.sleep(3)
    video = tq.rec_start(tag)
    time.sleep(seconds)  # hands off: the observation window
    tq.rec_stop()
    v8.interrupt()
    log = v8.applog(t0, os.path.join(v8.V6, f"{tag}.log"))
    lg = open(log).read()
    out = os.path.join(v8.V6, f"{tag}-motion.json")
    subprocess.run([sys.executable, os.path.join(tq.HERE, "motion.py"), video, "--fps", "30", "--bottom", "0.8", "--quiet", "--json", out],
                   capture_output=True)
    su = json.load(open(out))["summary"]
    res = {"tag": tag, "seconds": seconds,
           "prunes": len(re.findall(r"rows dropped|history pruned", lg)),
           "blank_page_lines": re.findall(r"blank page:[^\n]*", lg)[:20],
           "black_runs": [(r["start"], r["end"]) for r in su["black_runs"]],
           "flashes": su.get("flashes"), "valid": su["source"]["valid"], "load": v8.loads()}
    json.dump(res, open(os.path.join(v8.V6, f"{tag}-result.json"), "w"), indent=1)
    ev("hold", **{k: v for k, v in res.items() if k != "blank_page_lines"})
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
