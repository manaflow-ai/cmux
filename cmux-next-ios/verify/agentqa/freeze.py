"""The phone app is suspended (SIGSTOP) for `away` seconds while its chat streams
`seq: N`; the link times out meanwhile. Then it resumes (SIGCONT). Checks the phone
ends on the turn's end with every number, in order, and its running state."""
import aq, time, re, sys, json, os, signal
from aq import *
N = int(sys.argv[1]); away = float(sys.argv[2]); name = sys.argv[3]
s = aq._sim(); m = aq._mac()
rec_start(name)
t0 = send(f"seq: {N}")
time.sleep(3)
pid = app_pid()
os.kill(pid, signal.SIGSTOP); ts = time.time()
time.sleep(away)
os.kill(pid, signal.SIGCONT)
res = {"N": N, "away_s": away}
ev = [(round(t - ts, 1), k) for t, k in m.link_events(ts - 5)]
res["mac_link_events_rel_to_freeze"] = ev
while time.time() - t0 < 600:
    txt = " ".join(e.label for e in s.tree() if e.kind == "StaticText" and e.label)
    if f"{N}| seq-end" in txt:
        res["phone_end_after_resume_s"] = round(time.time() - ts - away, 1); break
    time.sleep(1)
else:
    res["phone_end_after_resume_s"] = None
time.sleep(3)
els = s.tree()
b = [e.label for e in els if e.kind == "StaticText" and e.label and re.search(r"\d+\|\d+\|", e.label)]
nums = [int(x) for x in re.findall(r"(\d+)\|", b[-1])] if b else []
miss = sorted(set(range(1, N + 1)) - set(nums))
res.update(count=len(nums), max=max(nums) if nums else None, ordered=nums == sorted(nums), missing=len(miss),
           missing_range=(miss[0], miss[-1]) if miss else None, tail=(b[-1][-60:] if b else None),
           buttons=[e.label for e in els if e.label in ("Stop", "Send")],
           working=[e.label for e in els if e.label and "Working" in str(e.label)])
shot(name + "-after"); rec_stop()
print(json.dumps(res))
