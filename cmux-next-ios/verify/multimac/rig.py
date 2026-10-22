"""Runs ON a cmux mini: the hidden, isolated rig Mac app (mac.py's Mac: own bundle id,
config, credentials; settings only through `open --env`, never an Info.plist edit).

    python3 rig.py prepare|launch|quit|status|device-id|cli ARGS...|link-events SINCE
"""
import glob
import json
import os
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE, "repo/cmux-next-ios/verify/e2e"))
from mac import Mac  # noqa: E402

PHONE = os.environ.get("MULTIMAC_PHONE", "multimac-phone")


def mac():
    src = glob.glob(os.path.join(BASE, "src", "*.app"))[0]
    m = Mac(os.path.join(BASE, "rig"), src)
    m.pid = (m.main_pids() or [None])[0]
    return m


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    m = mac()
    if cmd == "prepare":
        m.prepare()
        m.seed_pairing(names=[PHONE])
        print(json.dumps({"app": m.app, "bundle": m.bundle_id, "tag": m.tag}))
    elif cmd == "launch":
        t0 = m.launch(timeout=180)
        ok = m.wait_hostd(timeout=180)
        print(json.dumps({"pid": m.pid, "hostd": ok, "t0": t0}))
    elif cmd == "quit":
        print(json.dumps({"quit": m.quit()}))
    elif cmd == "status":
        print(json.dumps({"pids": m.main_pids(), "hostd": m.hostd_pids(), "device": m.device_id()}))
    elif cmd == "device-id":
        print(m.device_id() or "")
    elif cmd == "cli":
        # Raw CLI: `cli --json ...` passes --json to cmux (before the command).
        import subprocess
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
        env.update(CMUX_SOCKET_PATH=m.socket, CMUX_TAG=m.tag, CMUX_BUNDLE_ID=m.bundle_id)
        r = subprocess.run([m.cli, "--app-socket", m.socket, *args], capture_output=True, text=True, timeout=60, env=env)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    elif cmd == "link-events":
        print(json.dumps(m.link_events(float(args[0]))))
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
