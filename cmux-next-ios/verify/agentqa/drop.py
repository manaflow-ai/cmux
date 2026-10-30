"""A real link drop mid-stream: kill the Mac's cmux-mobile-host while the phone's chat
streams `seq: N`; the app restarts it and the phone redials. Checks the phone ends on
the turn's end with every number, in order."""
import aq, time, re, sys, json, os, signal
from aq import *
N = int(sys.argv[1]); kill_at = float(sys.argv[2]); name = sys.argv[3]
s = aq._sim(); m = aq._mac()
rec_start(name)
t0 = send(f"seq: {N}")
time.sleep(kill_at)
old = m.hostd_pids()
for p in old: os.kill(p, signal.SIGKILL)
res = {"N": N, "killed_hostd": old, "kill_at_s": kill_at}
t = time.time()
while time.time() - t < 60 and (not m.hostd_pids() or m.hostd_pids() == old):
    time.sleep(0.5)
res["hostd_back_s"] = round(time.time() - t, 1)
while time.time() - t0 < 600:
    txt = " ".join(e.label for e in s.tree() if e.kind == "StaticText" and e.label)
    if f"{N}| seq-end" in txt:
        res["phone_end_s"] = round(time.time() - t0, 1); break
    time.sleep(1)
time.sleep(2)
els = s.tree()
b = [e.label for e in els if e.kind == "StaticText" and e.label and re.search(r"\d+\|\d+\|", e.label)]
nums = [int(x) for x in re.findall(r"(\d+)\|", b[-1])] if b else []
miss = sorted(set(range(1, N + 1)) - set(nums))
res.update(count=len(nums), max=max(nums) if nums else None, ordered=nums == sorted(nums), missing=len(miss),
           first_missing=miss[:3], last_missing=miss[-3:], tail=(b[-1][-50:] if b else None),
           buttons=[e.label for e in els if e.label in ("Stop", "Send")],
           working=[e.label for e in els if e.label and str(e.label).startswith("Working")])
shot(name + "-after"); rec_stop()
print(json.dumps(res))
