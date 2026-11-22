import aq, time, sys, json, threading
from aq import *
N = int(sys.argv[1]); name = sys.argv[2]
s = aq._sim()
rec_start(name); perf_start(name)
t0 = send(f"md: {N}")
threading.Thread(target=lambda: (time.sleep(15), sample(5, name)), daemon=True).start()
res = {"N": N}
while time.time() - t0 < 900:
    txt = " ".join(e.label for e in s.tree() if e.label)
    if "Done: all sections streamed" in txt and not any(e.label == "Stop" for e in s.tree()):
        res["phone_end_s"] = round(time.time() - t0, 1); break
    time.sleep(1.0)
res["perf"] = perf_stop()
time.sleep(1); shot(name + "-end"); rec_stop()
print(json.dumps(res))
