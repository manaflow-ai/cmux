"""Runs ON the rig Mac (a cmux Mac mini): the parity rig's real tagged cmux-next app.

    python3 rmac.py prepare SIM_NAME... | launch | quit | hostd | name | device-id | cli ARGS...

Like verify/termqa/rmac.py, but the app bundle is never edited or re-signed: every
setting reaches it at launch with `open --env` (settings file, sign-in, pairing seed,
the agents' model route). An edited bundle is a new ad hoc identity whose Keychain
items wait on a prompt nobody sees.

Layout (~/cmux-next-ios-e2e/parity): e2e/ (the rig modules), rig/mac/<app> (unzipped once).
Agents: Claude through the team subrouter (`sr`'s server, port 31415), so
real model calls run on this mini without a person's Claude login.
"""
import json
import os
import subprocess
import sys

# The rig folder is this file's (~/cmux-next-ios-e2e/parity, ~/cmux-next-ios-e2e/p2, ...).
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE, "e2e"))
import mac as rig_mac  # noqa: E402
from mac import Mac  # noqa: E402

# The rig reads the DEBUG dev credential from CmuxAuthRuntime's source; this mini
# has only the rig modules, so the driver sends that one file next to them.
rig_mac.REPO = os.path.join(BASE, "repo")

# The team subrouter server over Tailscale, not the mini's loopback proxy: acpmux runs a
# phone-started Claude in its remote-chain Seatbelt profile, which shuts loopback.
# PQ_RIG_ENV: extra launch variables for a rig run, as JSON (e.g. {"CMUX_TUI_TEST_DISABLE_RESPAWN": "1"}
# so a terminal whose host is lost stays dead for the Restart Shell check).
EXTRA_ENV = json.loads(os.environ.get("PQ_RIG_ENV", "{}"))
AGENT_ENV = {
    "ANTHROPIC_BASE_URL": os.environ.get("PQ_ANTHROPIC_BASE_URL", "http://100.89.225.106:31415"),
    "ANTHROPIC_API_KEY": "sr-local",
}


class EnvMac(Mac):
    """No bundle edits: `prepare` writes settings files only; `launch` passes them."""

    def prepare(self):
        stamp = os.path.join(self.rig, "mac", ".source")
        src_id = f"{os.path.realpath(self.app)} {os.path.getmtime(self.info)}"
        if not os.path.exists(stamp) or open(stamp).read() != src_id:
            subprocess.run(["xattr", "-dr", "com.apple.quarantine", self.app], capture_output=True)
            open(stamp, "w").write(src_id)
        self.source_app = self.app
        return super().prepare()

    @property
    def launch_env(self):
        res = os.path.join(self.app, "Contents/Resources")
        path = ":".join([os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                         "/usr/sbin", "/sbin"])
        return dict(AGENT_ENV, **EXTRA_ENV, **{
            "CMUX_NEXT_CONFIG_FILE": self.config,
            "CMUX_AUTH_CREDENTIALS_FILE": self.creds,
            "CMUX_NEXT_IPHONE_PAIRING_SEED": self.pairing_seed,
            "CMUX_SHELL_INTEGRATION_DIR": f"{res}/shell-integration",
            "CMUX_BUNDLED_CLI_PATH": f"{res}/bin/cmux",
            "PATH": path,
        })

    @launch_env.setter
    def launch_env(self, value):
        pass


def mac():
    rig = os.path.join(BASE, "rig")
    apps = [a for a in os.listdir(os.path.join(rig, "mac")) if a.endswith(".app")]
    m = EnvMac(rig, os.path.join(rig, "mac", apps[0]))
    m.pid = (m.main_pids() or [None])[0]
    return m


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    m = mac()
    if cmd == "prepare":
        m.prepare()
        m.seed_pairing(names=args)
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
    elif cmd == "cli":
        r = m.cmux(*args, check=False, timeout=120)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)


if __name__ == "__main__":
    main()
