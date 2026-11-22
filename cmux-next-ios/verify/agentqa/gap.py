import aq, time, re, sys, json
from aq import *
N = int(sys.argv[1]); away = float(sys.argv[2]); name = sys.argv[3]
s = aq._sim()
rec_start(name)
t = send(f"seq: {N}")
time.sleep(4)
s.home(); tb = time.time()
time.sleep(away)
launch_app(terminate=(sys.argv[4] == "cold") if len(sys.argv) > 4 else True)
res = {"N": N, "away_s": away}
for i in range(120):
    els = s.tree()
    txt = " ".join(e.label for e in els if e.kind == "StaticText" and e.label)
    if f"{N}| seq-end" in txt:
        res["end_shown_after_return_s"] = round(time.time() - tb - away, 1); break
    time.sleep(0.5)
time.sleep(2); shot(f"{name}-after")
els = s.tree()
txt = " ".join(e.label for e in els if e.kind == "StaticText" and e.label)
res["end_shown"] = f"{N}| seq-end" in txt
res["buttons"] = [e.label for e in els if e.label in ("Stop", "Send")]
res["working"] = [e.label for e in els if e.label and str(e.label).startswith("Working")]
# The newest answer bubble: the longest StaticText with numbers.
bubbles = [e.label for e in els if e.kind == "StaticText" and e.label and "|" in e.label]
res["visible_tail"] = bubbles[-1][-80:] if bubbles else None
rec_stop()
print(json.dumps(res))
