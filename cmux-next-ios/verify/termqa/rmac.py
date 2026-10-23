"""Runs ON the remote Mac (a cmux Mac mini): prepares, launches and quits the rig's
real tagged cmux-next app there, and runs its bundled CLI. The phone (a simulator
on another machine) reaches it only through the real link (cmux-mobile-host), never a socket.

    python3 rmac.py prepare|launch|quit|hostd|name|cli ARGS...|link-events SINCE|device-id

Layout (~/cmux-next-ios-e2e/termqa): repo/cmux-next-ios/verify/e2e (rig modules),
rig/mac/<app> (unzipped once; prepared in place, no second copy: the mini's disk is small).
"""
import json
import os
import subprocess
import sys

# The rig instance is the folder this script sits in (~/cmux-next-ios-e2e/termqa on mini-2).
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE, "repo/cmux-next-ios/verify/e2e"))
from mac import Mac, pb  # noqa: E402


def mac():
    rig = os.path.join(BASE, "rig")
    apps = [a for a in os.listdir(os.path.join(rig, "mac")) if a.endswith(".app")]
    m = Mac(rig, os.path.join(rig, "mac", apps[0]))
    m.pid = (m.main_pids() or [None])[0]
    return m


def prepare(m, sim_names):
    stamp = os.path.join(m.rig, "mac", ".prepared")
    if not os.path.exists(stamp):
        p = m.info
        res = os.path.join(m.app, "Contents/Resources")
        pb(p, f"Set :LSEnvironment:CMUX_BUNDLED_CLI_PATH {res}/bin/cmux")
        pb(p, f"Set :LSEnvironment:CMUXD_UNIX_PATH {os.path.expanduser('~')}/Library/Application Support/cmux/cmuxd-dev-{m.tag}.sock")
        for k in ("LSEnvironment:CMUXTERM_REPO_ROOT", "SUFeedURL", "SUPublicEDKey"):
            pb(p, f"Delete :{k}", check=False)
        for key, value in (("CMUX_NEXT_CONFIG_FILE", m.config), ("CMUX_AUTH_CREDENTIALS_FILE", m.creds),
                           ("CMUX_NEXT_IPHONE_PAIRING_SEED", m.pairing_seed)):
            pb(p, f"Delete :LSEnvironment:{key}", check=False)
            pb(p, f"Add :LSEnvironment:{key} string {value}")
        subprocess.run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements,requirements,flags,runtime", m.app],
                       check=True, capture_output=True)
        subprocess.run(["xattr", "-dr", "com.apple.quarantine", m.app], capture_output=True)
        open(stamp, "w").write("ok")
    # Mac.prepare without its copy step: point its source at the app itself and
    # write the stamp it checks, so it only does config, credentials and helpers.
    src_id = f"{os.path.realpath(m.app)} {os.path.getmtime(m.info)}"
    open(os.path.join(m.rig, "mac", ".source"), "w").write(src_id)
    m.source_app = m.app
    m.prepare()
    m.seed_pairing(names=sim_names)
    return m


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    m = mac()
    if cmd == "prepare":
        prepare(m, args)
        print(json.dumps({"bundle": m.bundle_id, "tag": m.tag, "app": m.app}))
    elif cmd == "launch":
        m.launch()
        print(json.dumps({"pid": m.pid, "hostd": m.wait_hostd(120)}))
    elif cmd == "quit":
        print(json.dumps({"quit": m.quit()}))
    elif cmd == "hostd":
        print(json.dumps({"hostd": m.hostd_pids(), "main": m.main_pids()}))
    elif cmd == "name":
        print(m.computer_name())
    elif cmd == "device-id":
        print(m.device_id() or "")
    elif cmd == "link-events":
        print(json.dumps(m.link_events(float(args[0]))))
    elif cmd == "cli":
        r = m.cmux(*args, check=False, timeout=120)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)


if __name__ == "__main__":
    main()
