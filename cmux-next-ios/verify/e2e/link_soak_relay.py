#!/usr/bin/env python3
"""Runs link_soak.py on the simulator mini and answers its rig commands from here (the
simulator mini cannot ssh to the rig minis; this machine can reach both).

    python3 -u link_soak_relay.py SIM_HOST -- <link_soak.py arguments>
"""
import json
import shlex
import subprocess
import sys

host = sys.argv[1]
args = sys.argv[sys.argv.index("--") + 1:]
remote = ("cd ~/linkrel/src/cmux-next-ios/verify/e2e && export LINKSOAK_RELAY=1 "
          "DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer && "
          "exec python3 -u link_soak.py " + " ".join(shlex.quote(a) for a in args))
p = subprocess.Popen(["ssh", "-o", "ServerAliveInterval=30", host, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
for line in p.stdout:
    if not line.startswith("@@RIG "):
        print(line, end="", flush=True)
        continue
    ask = json.loads(line[6:])
    try:
        r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", ask["host"], ask["cmd"]], capture_output=True, text=True,
                           timeout=ask["timeout"])
        reply = {"rc": r.returncode, "out": r.stdout, "err": r.stderr}
    except subprocess.TimeoutExpired:
        reply = {"rc": 124, "out": "", "err": "timed out"}
    p.stdin.write(json.dumps(reply) + "\n")
    p.stdin.flush()
sys.exit(p.wait())
