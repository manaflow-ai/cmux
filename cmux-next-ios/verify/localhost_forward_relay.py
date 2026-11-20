#!/usr/bin/env python3
"""Runs localhost_forward_live.py on the simulator mini and answers its rig commands from
here (the simulator mini cannot ssh to the rig mini; this machine reaches both).

    python3 -u localhost_forward_relay.py SIM_HOST SIM_DIR -- <localhost_forward_live.py arguments>

SIM_DIR holds this checkout's cmux-next-ios/verify (and the files mac.py reads) on SIM_HOST.
"""
import json
import shlex
import subprocess
import sys

host, folder = sys.argv[1], sys.argv[2]
args = sys.argv[sys.argv.index("--") + 1:]
remote = (f"cd {folder}/cmux-next-ios/verify && export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer "
          "PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH && "
          "exec python3 -u localhost_forward_live.py " + " ".join(shlex.quote(a) for a in args))
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
