"""Runs ON a cmux mini: the hidden, isolated rig Mac app (mac.py's Mac: own bundle id,
config, credentials; settings only through `open --env`, never an Info.plist edit).

    python3 rig.py prepare|launch|quit|status|device-id|cli ARGS...|link-events SINCE
                   |ask TEXT|acpmux ARGS...

Several rigs can share one mini, each a copy of this folder with its own app (its
own bundle id): `MULTIMAC_DEVICE_NAME=NAME python3 rig.py launch` gives the rig a
name phones list it by.

The rig's acpmux runs in its own home (rig/acpmux, ACPMUX_HOME at launch) whose
default harness is acpmux's credit-free fake agent (BASE/fake_agent.py, copied
from cmux-tui/crates/acpmux/tests): `ask "ask: X"` starts a chat that asks a
permission, as Codex or Claude Code would.
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


ACPMUX_HOME = os.path.join(BASE, "rig", "acpmux")
FAKE_AGENT = os.path.join(BASE, "fake_agent.py")


def mac():
    src = glob.glob(os.path.join(BASE, "src", "*.app"))[0]
    m = Mac(os.path.join(BASE, "rig"), src)
    # This harness tests one computer's builds (grouped by the mini's own
    # machine id), so the rig keeps it.
    m.own_machine_id = False
    if os.path.exists(FAKE_AGENT):
        m.launch_env = {"ACPMUX_HOME": ACPMUX_HOME}
    # MULTIMAC_DEVICE_NAME: the name phones list this Mac by (a Debug build's
    # CMUX_NEXT_MOBILE_DEVICE_NAME, passed at launch with open --env), so two Macs can share one.
    if os.environ.get("MULTIMAC_DEVICE_NAME"):
        m.launch_env = dict(m.launch_env, CMUX_NEXT_MOBILE_DEVICE_NAME=os.environ["MULTIMAC_DEVICE_NAME"])
    # LINKREL_HOSTD_LOG: cmux-mobile-host's log filter (CMUX_MOBILE_LOG). The app hands hostd
    # no environment of its own, so a wrapper (CMUX_NEXT_MOBILE_HOST_BIN, Debug builds) sets it.
    if os.environ.get("LINKREL_HOSTD_LOG"):
        wrapper = os.path.join(BASE, "rig", "bin", "hostd-log")
        os.makedirs(os.path.dirname(wrapper), exist_ok=True)
        bundled = os.path.join(m.app, "Contents/Resources/bin/cmux-mobile-host")
        with open(wrapper, "w") as f:
            f.write(f'#!/bin/sh\nexport CMUX_MOBILE_LOG="{os.environ["LINKREL_HOSTD_LOG"]}"\nexec "{bundled}" "$@"\n')
        os.chmod(wrapper, 0o755)
        m.launch_env = dict(m.launch_env, CMUX_NEXT_MOBILE_HOST_BIN=wrapper)
    m.pid = (m.main_pids() or [None])[0]
    return m


def prepare_acpmux():
    """The fake agent as the default harness, asking for every tool (as `approvals-mac.sh`)."""
    if not os.path.exists(FAKE_AGENT):
        return False
    os.makedirs(ACPMUX_HOME, exist_ok=True)
    os.makedirs(os.path.join(BASE, "work"), exist_ok=True)
    os.chmod(ACPMUX_HOME, 0o700)
    config = {"harnesses": {"fake": {"argv": ["python3", FAKE_AGENT]}}, "defaultHarness": "fake",
              "permissionPolicy": "ask", "webAskingModes": {"fake": ["normal", "strict"]}}
    path = os.path.join(ACPMUX_HOME, "config.json")
    with open(path, "w") as f:
        json.dump(config, f)
    os.chmod(path, 0o600)
    return True


def acpmux(m, *args, detach=False):
    import subprocess
    env = dict(os.environ, ACPMUX_HOME=ACPMUX_HOME)
    cmd = [os.path.join(m.app, "Contents/Resources/bin/acpmux"), *args]
    if detach:
        log = open(os.path.join(BASE, "asks.log"), "a")
        subprocess.Popen(cmd, cwd=os.path.join(BASE, "work"), env=env, stdout=log, stderr=log, start_new_session=True)
        return 0
    r = subprocess.run(cmd, cwd=os.path.join(BASE, "work"), env=env, capture_output=True, text=True, timeout=60)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    return r.returncode


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    m = mac()
    if cmd == "prepare":
        m.prepare()
        # LINKREL_CREDS: an EMAIL=/PASSWORD= file (0600) of another account than the DEBUG dev
        # credential (a production test account for a --production build), so this rig
        # is not one of the many rig Macs every agent signs in to the dev account.
        if os.environ.get("LINKREL_CREDS"):
            pairs = dict(l.strip().split("=", 1) for l in open(os.path.expanduser(os.environ["LINKREL_CREDS"])) if "=" in l)
            fd = os.open(m.creds, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.fchmod(fd, 0o600)  # an existing file keeps its mode otherwise
            with os.fdopen(fd, "w") as f:
                f.write(f"CMUX_UITEST_STACK_EMAIL={pairs['EMAIL']}\nCMUX_UITEST_STACK_PASSWORD={pairs['PASSWORD']}\n")
        m.seed_pairing(names=[PHONE])
        print(json.dumps({"app": m.app, "bundle": m.bundle_id, "tag": m.tag, "acpmux": prepare_acpmux()}))
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
    elif cmd == "ask":
        acpmux(m, "new", "-m", "fake", "--cwd", os.path.join(BASE, "work"), "--detach", " ".join(args), detach=True)
        print("asked")
    elif cmd == "acpmux":
        sys.exit(acpmux(m, *args))
    elif cmd == "link-events":
        print(json.dumps(m.link_events(float(args[0]))))
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
