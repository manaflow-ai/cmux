#!/usr/bin/env python3
"""Runs brfz_soak.py on the simulator mini and answers its rig commands from here (the
simulator mini cannot ssh to the rig minis; this machine reaches both). As
verify/e2e/link_soak_relay.py, with the remote folder as an argument.

    python3 -u relay.py SIM_HOST REMOTE_VERIFY_DIR -- <brfz_soak.py arguments>
"""
import json
import shlex
import subprocess
import sys

host, remote_dir = sys.argv[1], sys.argv[2]
args = sys.argv[sys.argv.index("--") + 1:]
remote = (f"cd {remote_dir}/browser-freeze && export LINKSOAK_RELAY=1 "
          "DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer PATH=$HOME/.local/bin:/opt/homebrew/bin:$PATH && "
          "exec python3 -u brfz_soak.py " + " ".join(shlex.quote(a) for a in args))
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
