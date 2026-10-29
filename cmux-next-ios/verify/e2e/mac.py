"""The Mac half of the e2e rig: a REAL tagged cmux-next dev build, isolated and hidden.

Isolation (nothing of the user's "cmux NEXT mobile", cmux NEXT or NIGHTLY is touched):
- its own bundle id (the fleet tag: com.cmuxterm.app.debug.<tag>), so its own
  Keychain items, preferences, Application Support, daemon session, acpmux home,
  Chief home and control socket (/tmp/cmux-debug-<tag>.sock);
- its own settings file: LSEnvironment CMUX_NEXT_CONFIG_FILE=<rig>/config/cmux-next.json
  (CmuxConfigFile.overrideKey; an override is never seeded from the user's files);
- the fleet paths baked into LSEnvironment are rewritten to this copy;
- sign-in: CMUX_AUTH_CREDENTIALS_FILE=<rig>/secrets/dev-auth.env (0600), read by
  DogfoodCredentials in DEBUG builds only. It holds the DEBUG dev credential of
  CmuxAuthRuntime (the iOS "42" shortcut), extracted from source, never printed.

"Allow iPhone Connections" is turned on the documented person path for a test
instance: the isolated cmux-next.json gets `mobile.allowIPhoneConnections: true`
before launch (Settings > Mobile writes the same key).

Launch is `open -g -j -n` (background, hidden); the app is never activated.
Quit is a graceful NSRunningApplication.terminate() of this pid only. The app's
acpmux, Chief host and headless cmux-tui outlive that quit; a script that made the
Mac with `cleanup=True` ends them with `teardown()` (rig_cleanup.py), which also
keeps the rig's cleanup-registry/v1 records.
"""
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))

TERMINATE_SWIFT = r'''
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid) else { exit(0) }
_ = app.terminate()
let deadline = Date().addingTimeInterval(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "20")!)
while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
exit(app.isTerminated ? 0 : 3)
'''


def pb(plist, cmd, check=True):
    r = subprocess.run(["/usr/libexec/PlistBuddy", "-c", cmd, plist], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"PlistBuddy {cmd}: {r.stderr.strip()}")
    return r.stdout.strip()


def dev_credential():
    """(email, password) of the DEBUG dev credential (AuthCoordinator.sendCode "42")."""
    src = os.path.join(REPO, "Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthCoordinator.swift")
    text = open(src).read()
    m = re.search(r'CMUXAuthAutoLoginCredentials\(email:\s*"([^"]+)",\s*password:\s*"([^"]+)"\)', text)
    if not m:
        raise RuntimeError("DEBUG dev credential not found in CmuxAuthRuntime")
    return m.group(1), m.group(2)


RIG_BUNDLE = re.compile(r"\.mobile[.-]e2e[.-][0-9A-Za-z]+$")


def running_rig_apps():
    """[(pid, bundle_id, bundle_path)] of every running rig Mac app (a `cmux-mobile-e2e-*`
    tagged build, bundle id com.cmuxterm.app.debug.cmuxMobile.e2e.<sha8>), from lsappinfo."""
    out = subprocess.run(["lsappinfo", "list"], capture_output=True, text=True).stdout
    apps = []
    for entry in re.split(r"\n(?=\s*\d+\) )", out):
        bundle = re.search(r'bundleID="([^"]+)"', entry)
        pid = re.search(r"\bpid = (\d+)", entry)
        if not bundle or not pid or not RIG_BUNDLE.search(bundle.group(1)):
            continue
        # A quit app whose daemons outlive it is listed "exited-with-subordinates": not running.
        if "exited" in entry:
            continue
        path = re.search(r'bundle path="([^"]+)"', entry)
        try:
            os.kill(int(pid.group(1)), 0)  # lsappinfo can keep an app that already exited
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        apps.append((int(pid.group(1)), bundle.group(1), path.group(1) if path else "?"))
    return apps


def refuse_other_rigs(own_bundle_id):
    """Refuse to start while another tag's rig Mac app runs: both sign in to the same
    dev account, so the phone would list (and a step could act on) the other rig's Mac."""
    others = [a for a in running_rig_apps() if a[1] != own_bundle_id]
    if others and os.environ.get("CMUX_MOBILE_E2E_ALLOW_OTHER_RIGS") == "1":
        # Opt-in for runs that pick their Mac by device id only (the bench's
        # mac_discovered step) and never act on another rig's Mac: the other
        # app keeps running untouched.
        print(f"note: {len(others)} other rig Mac app(s) running; CMUX_MOBILE_E2E_ALLOW_OTHER_RIGS=1, choosing ours by device id")
        return
    if others:
        lines = "\n".join(f"  pid {pid}  {bundle}  {path}" for pid, bundle, path in others)
        raise SystemExit(
            "refusing to start: another e2e rig Mac app (a different cmux-mobile-e2e tag) is running and "
            f"shares the dev account:\n{lines}\n"
            "Wait for that run to finish (or, if it is yours and abandoned, quit that app), then rerun.")


# Each hidden rig app's own machine id (#24701). Every cmux build on one Mac
# registers that Mac's machine id, so the phone lists the computer once
# (MacRoster); several hidden rig apps on one mini then fold into one entry and
# one agent's rig hides another's. A DEBUG app passes this variable (32 hex
# digits) to cmux-mobile-host as its machine id.
RIG_MACHINE_ID_KEY = "CMUX_NEXT_MOBILE_MACHINE_ID"


_HARDWARE_UUID = None


def hardware_uuid():
    """This Mac's IOPlatformUUID (what cmux-mobile-host's own machine id uses):
    unlike the host name, it never changes with the network."""
    global _HARDWARE_UUID
    if _HARDWARE_UUID:
        return _HARDWARE_UUID
    out = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True).stdout
    m = re.search(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]+)"', out)
    if not m:
        raise RuntimeError("no IOPlatformUUID in ioreg output")
    _HARDWARE_UUID = m.group(1).upper()
    return _HARDWARE_UUID


def rig_machine_id(bundle_id, host_uuid=None):
    """A rig app's machine id: from this Mac's hardware UUID and the app's bundle
    id, the key of its device id (its cmux-mobile-host state folder), so one
    device record always gets one machine id and two rig apps never share one."""
    host_uuid = host_uuid if host_uuid is not None else hardware_uuid()
    return hashlib.sha256(f"cmux-rig-machine-id v1\0{host_uuid}\0{bundle_id}".encode()).hexdigest()[:32]


class Mac:
    def __init__(self, rig_dir, source_app, cleanup=False, log=None):
        self.rig = rig_dir
        self.source_app = source_app
        name = os.path.basename(source_app.rstrip("/"))
        self.app = os.path.join(rig_dir, "mac", name)
        self.info = os.path.join(self.app, "Contents/Info.plist")
        self.cli = os.path.join(self.app, "Contents/Resources/bin/cmux")
        self.config = os.path.join(rig_dir, "config", "cmux-next.json")
        self.creds = os.path.join(rig_dir, "secrets", "dev-auth.env")
        # Test-only pairing seed (DEBUG builds; SECURITY.md "Test-only pairing seed"):
        # the phones this hidden rig app trusts without the person-only Allow prompt.
        self.pairing_seed = os.path.join(rig_dir, "config", "iphone-pairing-seed.json")
        self.pid = None
        self.launch_env = {}
        # Listed on the phone as its own Mac (rig_machine_id), not as another
        # build of this computer. multimac's per-computer checks turn it off
        # here, and CMUX_RIG_SHARED_MACHINE_ID=1 turns it off for any rig (a
        # rig folder still holding an older rig.py copy).
        self.own_machine_id = True
        self._bundle = None
        self._tag = None
        # rig_cleanup.RigCleanup when the script asked for a teardown (cleanup=True):
        # prepare() records the rig dir, launch() the acpmux homes, teardown() ends them.
        self.cleanup = None
        if cleanup:
            from rig_cleanup import RigCleanup
            self.cleanup = RigCleanup(rig_dir, self.app, log=log)

    # ---- identity ----------------------------------------------------------
    @property
    def bundle_id(self):
        if not self._bundle:
            self._bundle = pb(self.info, "Print :CFBundleIdentifier")
        return self._bundle

    @property
    def tag(self):
        if not self._tag:
            self._tag = pb(self.info, "Print :LSEnvironment:CMUX_TAG")
        return self._tag

    @property
    def socket(self):
        return f"/tmp/cmux-debug-{self.tag}.sock"

    @property
    def hostd_state(self):
        return os.path.expanduser(f"~/Library/Application Support/{self.bundle_id}/cmux-mobile-host")

    def seed_pairing(self, names=(), ids=()):
        """Trust these phones (simulator names, link device ids) without the person-only
        Allow prompt: the DEBUG-only seed the rig app reads when a phone asks. Release
        builds ignore it; the rig never clicks Allow and never writes paired-devices.json."""
        devices = [{"name": n} for n in names] + [{"id": i} for i in ids]
        fd = os.open(self.pairing_seed, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"devices": devices}, f, indent=2)

    # ---- prepare -----------------------------------------------------------
    def prepare(self):
        if self.cleanup:
            self.cleanup.register_rig()  # the record goes in before the dir
        os.makedirs(os.path.join(self.rig, "mac"), exist_ok=True)
        os.makedirs(os.path.dirname(self.config), exist_ok=True)
        os.makedirs(os.path.dirname(self.creds), mode=0o700, exist_ok=True)
        os.chmod(os.path.dirname(self.creds), 0o700)
        stamp = os.path.join(self.rig, "mac", ".source")
        src_id = f"{os.path.realpath(self.source_app)} {os.path.getmtime(os.path.join(self.source_app, 'Contents/Info.plist'))}"
        if not (os.path.isdir(self.app) and os.path.exists(stamp) and open(stamp).read() == src_id):
            if os.path.exists(self.app):
                shutil.rmtree(self.app)
            subprocess.run(["ditto", self.source_app, self.app], check=True)
            self._bundle = self._tag = None
            # The copy stays byte for byte the fleet's (never an Info.plist edit or a
            # re-sign: a new ad hoc identity's Keychain reads wait on an unseen prompt and
            # cmux-mobile-host never starts). Its rig settings go in at launch (open --env).
            subprocess.run(["xattr", "-dr", "com.apple.quarantine", self.app], capture_output=True)
            open(stamp, "w").write(src_id)

        # Settings: the documented person path for a test instance (hand edit of its own cmux-next.json).
        cfg = {}
        if os.path.exists(self.config):
            try:
                cfg = json.load(open(self.config))
            except ValueError:
                cfg = {}
        cfg.setdefault("mobile", {})["allowIPhoneConnections"] = True
        json.dump(cfg, open(self.config, "w"), indent=2)
        # No phone is trusted until seed_pairing() names one.
        if not os.path.exists(self.pairing_seed):
            self.seed_pairing()
        # Credentials: 0600, never printed.
        email, password = dev_credential()
        fd = os.open(self.creds, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(f"CMUX_UITEST_STACK_EMAIL={email}\nCMUX_UITEST_STACK_PASSWORD={password}\n")
        os.chmod(self.creds, 0o600)
        bin_dir = os.path.join(self.rig, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        term = os.path.join(bin_dir, "terminate-pid")
        if not os.path.exists(term):
            src = os.path.join(bin_dir, "terminate-pid.swift")
            open(src, "w").write(TERMINATE_SWIFT)
            subprocess.run(["xcrun", "swiftc", "-O", "-o", term, src], check=True, capture_output=True)
        return self

    def rig_env(self):
        """The rig's settings for the app, passed at launch (open --env): its own
        config, credentials and pairing seed, and paths into this copy."""
        res = os.path.join(self.app, "Contents/Resources")
        return {
            "CMUX_SHELL_INTEGRATION_DIR": f"{res}/shell-integration",
            "CMUX_BUNDLED_CLI_PATH": f"{res}/bin/cmux",
            "CMUXD_UNIX_PATH": f"{os.path.expanduser('~')}/Library/Application Support/cmux/cmuxd-dev-{self.tag}.sock",
            "CMUX_NEXT_CONFIG_FILE": self.config,
            "CMUX_AUTH_CREDENTIALS_FILE": self.creds,
            "CMUX_NEXT_IPHONE_PAIRING_SEED": self.pairing_seed,
            # Its own machine id, so the phone lists this rig apart from the
            # other hidden rig apps on this Mac (#24701); off for a harness
            # that tests one computer's builds (own_machine_id = False).
            **({RIG_MACHINE_ID_KEY: rig_machine_id(self.bundle_id)}
               if self.own_machine_id and os.environ.get("CMUX_RIG_SHARED_MACHINE_ID") != "1" else {}),
        }

    # ---- lifecycle ---------------------------------------------------------
    def main_pids(self):
        exe_dir = os.path.join(self.app, "Contents/MacOS/")
        r = subprocess.run(["pgrep", "-f", exe_dir], capture_output=True, text=True)
        return [int(x) for x in r.stdout.split()]

    def hostd_pids(self):
        r = subprocess.run(["pgrep", "-f", os.path.join(self.app, "Contents/Resources/bin/cmux-mobile-host")], capture_output=True, text=True)
        return [int(x) for x in r.stdout.split()]

    def launch(self, timeout=90):
        """Start the app. With cleanup, SIGTERM and SIGHUP raise SystemExit from here on, so the script's
        `finally` (around launch) runs teardown()."""
        if self.cleanup:
            self.cleanup.install()
        t0 = time.time()
        if not self.main_pids():
            # CMUX_MOBILE_E2E_RB_HOST: a cmux-remote-browser-host.app (with its own CEF) the rig
            # app starts instead of the one it bundles (LocalRemoteBrowserHostLocator's
            # CMUX_NEXT_RB_HOST). Passed at launch, not in Info.plist: a changed bundle
            # is a new ad hoc identity, and the app's Keychain items from the last run
            # then wait on a prompt nobody sees (cmux-mobile-host never starts).
            # launch_env (for example CMUX_MOBILE_VIDEO_DROP_PERMILLE, which the app hands to
            # cmux-mobile-host) goes the same way.
            rb_host = os.environ.get("CMUX_MOBILE_E2E_RB_HOST", "")
            env = dict(self.rig_env(), **self.launch_env, **({"CMUX_NEXT_RB_HOST": rb_host} if rb_host else {}))
            flags = [x for k, v in env.items() for x in ("--env", f"{k}={v}")]
            subprocess.run(["open", "-g", "-j", "-n", *flags, self.app], check=True)
        deadline = time.time() + timeout
        while time.time() < deadline:
            pids = self.main_pids()
            if pids and self.cmux("app", "ping", check=False, timeout=5).returncode == 0:
                self.pid = pids[0]
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("Mac app did not answer on its control socket")
        if self.cleanup:
            self.cleanup.register_daemons()
        return t0

    def wait_hostd(self, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.hostd_pids():
                return True
            time.sleep(0.5)
        return False

    def quit(self, timeout=30):
        pids = self.main_pids()
        for pid in pids:
            subprocess.run([os.path.join(self.rig, "bin/terminate-pid"), str(pid), str(timeout)])
        deadline = time.time() + timeout
        while time.time() < deadline and (self.main_pids() or self.hostd_pids()):
            time.sleep(0.3)
        return not self.main_pids()

    def teardown(self, timeout=30):
        """The end of a rig run: quit the app, then stop what outlives it (its acpmux
        daemons by their own shutdown, its headless cmux-tui, leftovers by exact PID) and
        remove the rig's recorded dirs (rig_cleanup.py). Needs Mac(..., cleanup=True)."""
        quit_ok = self.quit(timeout)
        if self.cleanup:
            self.cleanup.end()
        return quit_ok

    # ---- CLI -----------------------------------------------------------------
    def cmux(self, *args, check=True, timeout=60, json_out=False):
        cmd = [self.cli, "--app-socket", self.socket]
        if json_out:
            cmd.append("--json")
        cmd += list(args)
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
        env["CMUX_SOCKET_PATH"] = self.socket
        env["CMUX_TAG"] = self.tag
        env["CMUX_BUNDLE_ID"] = self.bundle_id
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired as e:
            # A loaded mini answers late: an unchecked call (a readiness ping)
            # reads it as "not yet" and asks again, instead of ending the run.
            if check:
                raise
            r = subprocess.CompletedProcess(cmd, 124, e.stdout or "", f"timed out after {timeout} s")
        if check and r.returncode != 0:
            raise RuntimeError(f"cmux {' '.join(args)}: {(r.stderr or r.stdout).strip()[:400]}")
        if json_out and r.returncode == 0:
            out = r.stdout.strip()
            try:
                return json.loads(out) if out else None
            except ValueError:
                return [json.loads(l) for l in out.splitlines() if l.strip()]
        return r

    def device_id(self):
        f = os.path.join(self.hostd_state, "device-id")
        if os.path.exists(f):
            v = open(f).read().strip()
            if v:
                return v
        for path in glob.glob(os.path.join(self.hostd_state, "**/*"), recursive=True):
            if os.path.isfile(path) and os.path.getsize(path) < 4096:
                try:
                    text = open(path).read()
                except (UnicodeDecodeError, OSError):
                    continue
                m = re.search(r'"?device_?[iI]d"?\s*[:=]\s*"([^"]+)"', text)
                if m:
                    return m.group(1)
        return None


    def link_events(self, since):
        """[(epoch, "up"|"down")] from cmux-mobile-host's log after `since` (same host clock)."""
        import datetime
        path = os.path.join(self.hostd_state, "cmux-mobile-host.log")
        out = []
        if not os.path.exists(path):
            return out
        for line in open(path, errors="replace"):
            m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z .*cmux_mobile_host::host: link (up|down)", line)
            if not m:
                continue
            ts = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp()
            if ts >= since:
                out.append((ts, m.group(2)))
        return out

    def computer_name(self):
        r = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True)
        return r.stdout.strip() or "Mac"
