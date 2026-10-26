"""The e2e rig's teardown and its cleanup-registry/v1 records.

A rig run starts a hidden tagged DEV app (mac.py). The app starts its own acpmux
(ACPMUX_HOME=~/.acpmux/builds/<key>), its Chief host, which starts the Chief's acpmux
(~/.cmux/chief/<key>/acpmux), and headless cmux-tui sessions. They all keep running
after the app quits (keep-on-quit). A script that only quits the app leaves them
reparented to launchd for days (cmux12, October 2026: four `acpmux daemon run` from
two chief_info_live.py and chief_invite_live.py runs).

`RigCleanup` ends a rig:

1. `register_rig()` before the rig dir is made, and `register_daemons()` after launch,
   write one cleanup-registry/v1 record per dir (tool "cmux-next-ios-e2e"): the rig dir,
   owned by this script, and each acpmux home of the rig's bundle, owned by the daemon
   that runs in it (its pid and start time);
2. `end()` (also on a failure, Ctrl-C or SIGTERM once `install()` ran) stops every
   process of the bundle with scripts/cmux-next/tag_teardown.py: each acpmux by its own
   `acpmux daemon shutdown --end-agents` with its own ACPMUX_HOME, the headless cmux-tui
   by `session shutdown`, and a leftover only by its exact PID; never a pattern kill;
3. then removes each recorded dir whose owner is gone, and its record. A dir whose
   daemon still runs, or that is not a home of this bundle, is kept with its record.

Record format (cleanup-registry/v1): one JSON file per dir in
${CMUX_CLEANUP_REGISTRY:-${XDG_STATE_HOME:-~/.local/state}/cleanup-registry}, named
<tool>-<first 16 hex of sha256(path)>.json, written atomically.
"""
import calendar
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

TOOL = "cmux-next-ios-e2e"
SCHEMA = "cleanup-registry/v1"
MAX_AGE_HOURS = 12

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))


def registry_dir():
    if os.environ.get("CMUX_CLEANUP_REGISTRY"):
        return os.environ["CMUX_CLEANUP_REGISTRY"]
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "cleanup-registry")


def canonical(path):
    """PATH with its existing ancestors' links resolved (/tmp/x is /private/tmp/x)."""
    path = os.path.normpath(os.path.abspath(path))
    head, tail = path, []
    while not os.path.exists(head) and os.path.dirname(head) != head:
        head, name = os.path.split(head)
        tail.insert(0, name)
    return os.path.join(os.path.realpath(head), *tail)


def record_file(path, directory=None):
    digest = hashlib.sha256(path.encode()).hexdigest()[:16]
    return os.path.join(directory or registry_dir(), f"{TOOL}-{digest}.json")


def process_start(pid):
    """PID's start time in Unix seconds (`ps lstart`, as the registry's readers take it), or None."""
    env = dict(os.environ, LC_ALL="C", TZ="UTC")
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                             env=env, timeout=10).stdout
        return calendar.timegm(time.strptime(" ".join(out.split()), "%a %b %d %H:%M:%S %Y"))
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def same_process(pid, start):
    """True while PID runs and started at START (a reused pid is another process)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    now = process_start(pid)
    return now is None or start is None or abs(now - start) <= 2


def register(path, owner_pid, owner_start, kind="job", owner_pgid=0, directory=None):
    """Write the record of PATH, owned by OWNER_PID (started at OWNER_START). Returns the canonical path."""
    path = canonical(path)
    directory = directory or registry_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    record = {"schema": SCHEMA, "tool": TOOL, "kind": kind, "path": path, "host": os.uname().nodename,
              "created": int(time.time()), "owner_pid": owner_pid, "owner_start": owner_start,
              "cleanup": "trap", "max_age_hours": MAX_AGE_HOURS}
    if owner_pgid > 1:
        record["owner_pgid"] = owner_pgid
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".record-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(record) + "\n")
        os.replace(tmp, record_file(path, directory))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return path


def unregister(path, directory=None):
    try:
        os.unlink(record_file(canonical(path), directory))
    except FileNotFoundError:
        pass


def read_record(path, directory=None):
    try:
        with open(record_file(canonical(path), directory)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def build_homes(bundle_id, home=None):
    """The acpmux homes a build of BUNDLE_ID may own: ~/.acpmux/builds/<key> and
    ~/.cmux/chief/<key>/acpmux, where <key> is the bundle id or starts with it plus `--`
    (BuildIdentity: a hash or a shipped tag after it)."""
    home = home or os.path.expanduser("~")
    key = re.escape(bundle_id) + r"(?:--[A-Za-z0-9._-]+)?"
    acp = re.escape(canonical(os.path.join(home, ".acpmux", "builds")))
    chief = re.escape(canonical(os.path.join(home, ".cmux", "chief")))
    return re.compile(rf"(?:{acp}/{key}|{chief}/{key}/acpmux)")


def _teardown_module():
    path = os.path.join(REPO, "scripts", "cmux-next")
    if path not in sys.path:
        sys.path.insert(0, path)
    import tag_teardown
    return tag_teardown


class RigCleanup:
    def __init__(self, rig_dir, app, bundle_id=None, log=None, directory=None, teardown=None):
        self.rig = canonical(rig_dir)
        self.app = app
        self._bundle_id = bundle_id
        self.log = log or (lambda line: print(line, flush=True))
        self.directory = directory
        self._teardown = teardown
        self.homes = {}  # canonical ACPMUX_HOME -> (daemon pid, start)
        self.done = False

    @property
    def bundle_id(self):
        """The rig app's CFBundleIdentifier (read once the copy exists)."""
        if not self._bundle_id:
            import plistlib
            with open(os.path.join(self.app, "Contents", "Info.plist"), "rb") as f:
                self._bundle_id = plistlib.load(f)["CFBundleIdentifier"]
        return self._bundle_id

    @property
    def teardown(self):
        if self._teardown is None:
            self._teardown = _teardown_module().TagTeardown(self.app, log=lambda line: self.log(line))
        return self._teardown

    def install(self):
        """SIGTERM and SIGHUP raise SystemExit, so the script's `finally` runs end()."""
        self.teardown.install()

    def register_rig(self):
        """The rig dir's record, owned by this script; written before the dir is made."""
        pid = os.getpid()
        register(self.rig, pid, process_start(pid), owner_pgid=os.getpgrp(), directory=self.directory)

    def _daemons(self):
        """(pid, ACPMUX_HOME) of each `acpmux daemon run` of the rig's bundle now."""
        acpmux = os.path.join(self.teardown.bin, "acpmux") + " daemon run"
        found = []
        for pid, command in self.teardown.processes():
            if command != acpmux and not command.startswith(acpmux + " "):
                continue
            env = (_teardown_module().procargs(pid) or ([], {}))[1]
            if env.get("ACPMUX_HOME"):
                found.append((pid, canonical(env["ACPMUX_HOME"])))
        return found

    def register_daemons(self):
        """A record for each acpmux home of the bundle, owned by the daemon that runs in it.
        Call after launch, and again after a relaunch: it arms end() again."""
        self.done = False
        self.teardown.done = False
        homes = build_homes(self.bundle_id)
        for pid, home in self._daemons():
            if not homes.fullmatch(home):
                self.log(f"teardown: acpmux {pid} runs in {home}, not a home of {self.bundle_id}; not recorded")
                continue
            start = process_start(pid)
            if self.homes.get(home) != (pid, start):
                register(home, pid, start, directory=self.directory)
                self.homes[home] = (pid, start)
        return dict(self.homes)

    def end(self, remove_rig=True):
        """Stop the bundle's processes, then remove each recorded dir whose owner is gone."""
        if self.done:
            return
        try:
            self.register_daemons()
        except Exception as error:  # noqa: BLE001 - the teardown still runs
            self.log(f"teardown: reading the rig's daemons failed: {error}")
        self.done = True
        self.teardown.end()
        homes = build_homes(self.bundle_id)
        for home, (pid, start) in sorted(self.homes.items()):
            if same_process(pid, start):
                self.log(f"teardown: acpmux {pid} still runs; {home} and its record are kept")
                continue
            if not homes.fullmatch(home):
                continue
            shutil.rmtree(home, ignore_errors=True)
            if os.path.exists(home):
                self.log(f"teardown: {home} could not be removed; its record is kept")
                continue
            unregister(home, self.directory)
            self.log(f"teardown: removed acpmux home {home}")
        if remove_rig:
            left = self.teardown.processes()
            if left:
                self.log(f"teardown: {len(left)} processes of the bundle still run; the rig dir and its record are kept")
            else:
                shutil.rmtree(self.rig, ignore_errors=True)
                if not os.path.exists(self.rig):
                    unregister(self.rig, self.directory)
                    self.log(f"teardown: removed rig dir {self.rig}")
