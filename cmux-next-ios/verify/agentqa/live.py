import aq, time, re, sys, json, threading
from aq import *
N = int(sys.argv[1]); name = sys.argv[2]
s = aq._sim()
rec_start(name); perf_start(name)
t0 = send(f"seq: {N}")
res = {"N": N}
smp = {}
def take():
    time.sleep(float(sys.argv[3]) if len(sys.argv) > 3 else 20)
    smp["path"] = sample(5, name)
threading.Thread(target=take, daemon=True).start()
last_seen, marks = 0, []
while time.time() - t0 < 900:
    txt = " ".join(e.label for e in s.tree() if e.kind == "StaticText" and e.label)
    m = re.findall(r"(\d+)\|", txt)
    if m:
        last_seen = max(last_seen, max(int(x) for x in m))
        marks.append((round(time.time() - t0, 1), last_seen))
    if f"{N}| seq-end" in txt:
        res["phone_end_s"] = round(time.time() - t0, 1); break
    time.sleep(1.0)
res["progress"] = marks[::max(1, len(marks) // 12)]
res["perf"] = perf_stop()
rec_stop()
print(json.dumps(res))
