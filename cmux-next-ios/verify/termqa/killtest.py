import os, re, subprocess, sys, time, json, datetime
L = os.path.expanduser("~/Library/Application Support/com.cmuxterm.app.debug.cmuxMobile.e2e.604fc689/cmux-mobile-host/cmux-mobile-host.log")
gaps = [float(x) for x in sys.argv[1:]] or [20, 25, 40, 70]
def ts(line):
    m = re.match(r"(\S+Z)", line)
    return datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp() if m else None
res = []
for i, gap in enumerate([0] + gaps):
    if gap:
        time.sleep(gap)  # intentional spacing between injected faults, not synchronization
    size = os.path.getsize(L)
    t_kill = time.time()
    subprocess.run(["pkill", "-9", "-f", "cmux-mobile-e2e-604fc689.app/Contents/Resources/bin/cmux-mobile-host"])  # the rig's hostd only; other agents run their own
    up = None
    deadline = t_kill + 90
    while time.time() < deadline and up is None:
        time.sleep(0.1)
        with open(L) as f:
            f.seek(size)
            for line in f:
                if "link up" in line:
                    up = (ts(line), line.strip()[:160]); break
    r = {"kill": round(t_kill, 3), "gap_s": gap, "link_up": up and round(up[0], 3), "reconnect_s": up and round(up[0] - t_kill, 2)}
    print(json.dumps(r), flush=True); res.append(r)
