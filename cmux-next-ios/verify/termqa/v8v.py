"""Round-8 verifier (fresh, termverify8): runs the v8* rig helpers with evidence
redirected to verify8v/ and raw video to ~/cmux-next-ios-e2e/termqa-raw/tv8v/.

    python3 v8v.py v8_hold TAG [args...]
"""
import importlib
import os
import sys

import tq
import v8

V = os.path.abspath(os.path.join(tq.HERE, "../design/terminal/verify8v"))
RAW = os.path.expanduser("~/cmux-next-ios-e2e/termqa-raw/tv8v")
os.makedirs(V, exist_ok=True)
os.makedirs(RAW, exist_ok=True)
v8.V6 = V
v8.RAW6 = RAW
tq.RAW = RAW

_rec_start = tq.rec_start


def _rec_start_logged(name):
    path = _rec_start(name)
    v8.ev("rec_start", name=name, path=path, t0=tq.load()["rec"]["t0"])
    return path


tq.rec_start = _rec_start_logged

# The rig's `--tap-style simulator` tap started hanging for 25 s on every call at 03:50
# (round 8); the automatic style still works. Try the rig's style briefly, then automatic.
import subprocess as _sp
import time as _time
from sim import Sim as _Sim


def _tap(self, x, y):
    t = _time.time()
    for style, to in (("simulator", 6), ("automatic", 30)):
        try:
            _sp.run(["axe", "tap", "--udid", self.udid, "-x", f"{x:.1f}", "-y", f"{y:.1f}", "--tap-style", style],
                    capture_output=True, text=True, timeout=to)
            return t
        except _sp.TimeoutExpired:
            continue
    raise RuntimeError(f"tap {x},{y} failed in both styles")


_Sim.tap = _tap

if __name__ == "__main__":
    mod = importlib.import_module(sys.argv[1])
    sys.argv = [sys.argv[1] + ".py"] + sys.argv[2:]
    mod.main()
