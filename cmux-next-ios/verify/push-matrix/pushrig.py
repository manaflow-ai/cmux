"""Runs ON a cmux mini: the rich-push rig (verify/push-matrix.md).

One hidden, isolated rig Mac app (a real fleet build of the branch, mac.py's Mac: own
bundle id, config, credentials and acpmux home with acpmux's credit-free fake agent;
settings only through `open --env`) and one headless simulator, both on this mini. The
Mac's cmux-mobile-host reaches the dev Worker through notify-tap.mjs (a pass-through that
records each /notify body), so every pushed payload is one the real host produced.

    python3 pushrig.py prepare            # copy the app, settings, fake agent config, pairing seed
    python3 pushrig.py launch             # notify-tap + the Mac app (hidden) + hostd
    python3 pushrig.py ask TEXT           # a fake-agent session with TEXT (ask:, question:, ...)
    python3 pushrig.py prompt SESSION TEXT
    python3 pushrig.py sessions | perms | tail-log N | device-id | status | quit
    python3 pushrig.py cli ARGS...        # the rig app's own cmux CLI
    python3 pushrig.py captured           # notify bodies so far (JSON lines)

Layout: ~/richpush-verify/{rig,mac-src,src,logs}; this file in
src/cmux-next-ios/verify/push-matrix/.
"""
import glob
import json
import os
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from mac import Mac  # noqa: E402

ROOT = os.path.expanduser("~/richpush-verify")
RIG = os.path.join(ROOT, "rig")
TAP_PORT = int(os.environ.get("PUSHRIG_TAP_PORT", "18890"))
CAPTURE = os.path.join(RIG, "notify-capture.jsonl")
PHONE = os.environ.get("PUSHRIG_PHONE", "richpush-phone")
FAKE = os.path.abspath(os.path.join(HERE, "../../../cmux-tui/crates/acpmux/tests/fake_agent.py"))
AGENT = os.path.abspath(os.path.join(HERE, "../scripts/e2e_agent.py"))
ACPMUX_HOME = os.path.join(RIG, "acpmux")
WORK = os.path.join(RIG, "work")


def mac():
    src = glob.glob(os.path.join(ROOT, "mac-src", "*.app"))[0]
    m = Mac(RIG, src)
    m.launch_env = {
        "CMUX_NEXT_MOBILE_API_URL": f"http://127.0.0.1:{TAP_PORT}",
        "ACPMUX_HOME": ACPMUX_HOME,
        "FAKE_AGENT": FAKE,
    }
    m.pid = (m.main_pids() or [None])[0]
    return m


def acpmux(m, *args, timeout=60):
    exe = os.path.join(m.app, "Contents/Resources/bin/acpmux")
    env = dict(os.environ, ACPMUX_HOME=ACPMUX_HOME, FAKE_AGENT=FAKE)
    return subprocess.run([exe, *args], capture_output=True, text=True, timeout=timeout, env=env, cwd=WORK)


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    m = mac()
    if cmd == "prepare":
        m.prepare()
        m.seed_pairing(names=[PHONE])
        os.makedirs(ACPMUX_HOME, mode=0o700, exist_ok=True)
        os.makedirs(WORK, exist_ok=True)
        cfg = {"harnesses": {"fake": {"argv": ["/usr/bin/env", f"FAKE_AGENT={FAKE}", "python3", AGENT]}},
               "defaultHarness": "fake", "permissionPolicy": "ask",
               "webAskingModes": {"fake": ["normal", "strict"]}}
        path = os.path.join(ACPMUX_HOME, "config.json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(cfg, f, indent=2)
        print(json.dumps({"app": m.app, "bundle": m.bundle_id, "tag": m.tag}))
    elif cmd == "launch":
        tap = os.path.join(HERE, "notify-tap.mjs")
        if subprocess.run(["pgrep", "-f", f"notify-tap.mjs {TAP_PORT}"], capture_output=True).returncode != 0:
            log = open(os.path.join(RIG, "notify-tap.log"), "a")
            # PUSHRIG_UPSTREAM: another cmux-mobile-api (a local `wrangler dev` of a branch's Worker).
            upstream = [os.environ["PUSHRIG_UPSTREAM"]] if os.environ.get("PUSHRIG_UPSTREAM") else []
            subprocess.Popen(["node", tap, str(TAP_PORT), CAPTURE, *upstream], stdout=log, stderr=log, start_new_session=True)
        t0 = m.launch(timeout=180)
        ok = m.wait_hostd(timeout=180)
        print(json.dumps({"pid": m.pid, "hostd": ok, "t0": t0}))
    elif cmd == "ask":
        r = subprocess.Popen(
            [os.path.join(m.app, "Contents/Resources/bin/acpmux"), "new", "-m", "fake", "--cwd", WORK, "--detach", " ".join(args)],
            env=dict(os.environ, ACPMUX_HOME=ACPMUX_HOME, FAKE_AGENT=FAKE), cwd=WORK,
            stdout=open(os.path.join(RIG, "asks.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
        print(json.dumps({"asked": " ".join(args), "pid": r.pid}))
    elif cmd == "prompt":
        r = acpmux(m, "send", args[0], " ".join(args[1:]))
        sys.stdout.write(r.stdout + r.stderr)
    elif cmd == "sessions":
        r = acpmux(m, "ls", "--json")
        sys.stdout.write(r.stdout or r.stderr)
    elif cmd == "acpmux":
        r = acpmux(m, *args)
        sys.stdout.write(r.stdout + r.stderr)
        sys.exit(r.returncode)
    elif cmd == "tail-log":
        path = os.path.join(m.hostd_state, "cmux-mobile-host.log")
        n = args[0] if args else "40"
        sys.stdout.write(subprocess.run(["tail", "-n", n, path], capture_output=True, text=True).stdout)
    elif cmd == "captured":
        sys.stdout.write(open(CAPTURE).read() if os.path.exists(CAPTURE) else "")
    elif cmd == "device-id":
        print(m.device_id() or "")
    elif cmd == "status":
        print(json.dumps({"pids": m.main_pids(), "hostd": m.hostd_pids(), "device": m.device_id(), "bundle": m.bundle_id}))
    elif cmd == "cli":
        r = m.cmux(*args, check=False, timeout=60)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    elif cmd == "quit":
        print(json.dumps({"quit": m.quit()}))
        subprocess.run(["pkill", "-f", f"notify-tap.mjs {TAP_PORT}"])
    else:
        sys.exit(f"unknown command {cmd}: {shlex.join(sys.argv)}")


if __name__ == "__main__":
    main()
