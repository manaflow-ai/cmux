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
import fcntl
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


class RegistryLock:
    """The registry's flock (`<registry>/.lock`), the one its reapers hold from a record's liveness check until the
    path and record are gone."""

    def __init__(self, directory=None):
        self.directory = directory or registry_dir()

    def __enter__(self):
        os.makedirs(self.directory, mode=0o700, exist_ok=True)
        self.fd = os.open(os.path.join(self.directory, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


class Held(Exception):
    """Another live owner's record names the path."""


def group_alive(pgid):
    """True while a process of group PGID that is not a zombie runs (as the registry's readers count a group)."""
    if not isinstance(pgid, int) or pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        done = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return True
    if done.returncode != 0:
        return True  # an unreadable process table is not evidence the group is gone
    out = done.stdout
    return any(f[0] == str(pgid) and not f[1].startswith("Z") for f in (l.split() for l in out.splitlines()) if len(f) == 2)


def record_alive(record):
    """True when a record's owner (pid and start) or a process of its group still runs; also when it names no owner."""
    pid = record.get("owner_pid")
    if group_alive(record.get("owner_pgid")):
        return True
    if not isinstance(pid, int) or pid <= 0:
        return True
    return same_process(pid, record.get("owner_start"))


def owned(record, owner_pid, owner_start):
    """True when RECORD names exactly this owner."""
    return bool(record) and (record.get("owner_pid"), record.get("owner_start")) == (owner_pid, owner_start)


def register(path, owner_pid, owner_start, kind="job", owner_pgid=0, directory=None):
    """Write the record of PATH, owned by OWNER_PID (started at OWNER_START, a number), under the registry lock.
    Raises Held when another owner that still runs holds the path's record, ValueError without a start time.
    Returns the canonical path."""
    if not (_positive(owner_pid, integral=True) and _positive(owner_start, integral=True)):
        raise ValueError(f"no start time for owner pid {owner_pid}")
    path = canonical(path)
    directory = directory or registry_dir()
    with RegistryLock(directory):
        try:
            held = read_record(path, directory, strict=True)
        except Unreadable as error:
            raise Held(f"{path} has a record that cannot be read ({error}); it is never taken over")
        if held and not owned(held, owner_pid, owner_start) and record_alive(held):
            raise Held(f"{path} is held by live owner pid {held.get('owner_pid')} (group {held.get('owner_pgid')})")
        _write(path, owner_pid, owner_start, kind, owner_pgid, directory)
    return path


def _write(path, owner_pid, owner_start, kind, owner_pgid, directory):
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


def unregister(path, directory=None):
    with RegistryLock(directory):
        try:
            os.unlink(record_file(canonical(path), directory))
        except FileNotFoundError:
            pass


def remove_recorded(path, owner_pid, owner_start, directory=None):
    """Under the registry lock: only when PATH's record is there and still names this owner, and the owner is
    gone, remove PATH and then its record. True when both are gone. A missing or unreadable record keeps PATH."""
    with RegistryLock(directory):
        if not owned(read_record(path, directory), owner_pid, owner_start):
            return False  # no record proves it ours, or another run registered it since
        if same_process(owner_pid, owner_start):
            return False
        shutil.rmtree(path, ignore_errors=True)
        if os.path.exists(path):
            return False
        try:
            os.unlink(record_file(canonical(path), directory))
        except FileNotFoundError:
            pass
        return True


def _positive(value, integral=False):
    """A finite number above zero (an int when INTEGRAL), never a bool."""
    if isinstance(value, bool) or not isinstance(value, int if integral else (int, float)):
        return False
    return value == value and value not in (float("inf"), float("-inf")) and value > 0


# The exact fields this tool writes (_write), and their types: a record with any other key, a missing one or
# another type is not one of ours, so it is never taken over and never acted on.
FIELDS = {"schema": str, "tool": str, "kind": str, "path": str, "host": str, "created": int, "owner_pid": int,
          "owner_start": int, "cleanup": str, "max_age_hours": int}
OPTIONAL = {"owner_pgid": int}


def invalid(record, path):
    """Why RECORD is not exactly a cleanup-registry/v1 job record this tool wrote for PATH on this host, or ''."""
    if not isinstance(record, dict):
        return "not an object"
    keys = set(record)
    if not set(FIELDS) <= keys or not keys <= set(FIELDS) | set(OPTIONAL):
        return f"fields {sorted(keys)} are not this tool's"
    for key, kind in {**FIELDS, **OPTIONAL}.items():
        if key in record and (isinstance(record[key], bool) or not isinstance(record[key], kind)):
            return f"{key} is not a {kind.__name__}"
    expected = {"schema": SCHEMA, "tool": TOOL, "kind": "job", "path": path, "host": os.uname().nodename,
                "cleanup": "trap", "max_age_hours": MAX_AGE_HOURS}
    for key, value in expected.items():
        if record[key] != value:
            return f"{key} is {record[key]!r}, not {value!r}"
    if not all(_positive(record[key], integral=True) for key in ("created", "owner_pid", "owner_start")):
        return "created, owner_pid and owner_start must be positive"
    if "owner_pgid" in record and not _positive(record["owner_pgid"], integral=True):
        return "owner_pgid must be positive"
    return ""


class Unreadable(Exception):
    """A record file is there but cannot be read: never taken over, never acted on."""


def read_record(path, directory=None, strict=False):
    """PATH's record, or None when there is none. An unreadable or malformed one is None too, or, with STRICT,
    raises Unreadable."""
    try:
        with open(record_file(canonical(path), directory)) as f:
            record = json.load(f)
        why = invalid(record, canonical(path))
        if why:
            raise ValueError(why)
        return record
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        if strict:
            raise Unreadable(f"{record_file(canonical(path), directory)}: {error}")
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
            homes = build_homes(self.bundle_id)
            self._teardown = _teardown_module().TagTeardown(
                self.app, log=lambda line: self.log(line),
                acpmux_home_ok=lambda home: bool(homes.fullmatch(canonical(home))))
        return self._teardown

    def install(self):
        """SIGTERM and SIGHUP raise SystemExit, so the script's `finally` runs end()."""
        self.teardown.install()

    def register_rig(self):
        """The rig dir's record, owned by this script; written before the dir is made. A run never starts without
        it: SystemExit while another live run of this rig holds it, or when it cannot be written."""
        pid = os.getpid()
        self.rig_owner = (pid, process_start(pid))
        try:
            register(self.rig, *self.rig_owner, owner_pgid=os.getpgrp(), directory=self.directory)
        except Held as held:
            raise SystemExit(f"refusing to start: {held} (another run of this rig)")
        except (OSError, ValueError) as error:
            raise SystemExit(f"refusing to start: the rig dir's cleanup record was not written: {error}")
        made = not os.path.exists(self.rig)
        os.makedirs(self.rig, exist_ok=True)
        # A reaper that saw the record before the dir existed may have dropped it ("its dir is gone"); the dir
        # exists now, so a record written again stays.
        try:
            if not owned(read_record(self.rig, self.directory), *self.rig_owner):
                register(self.rig, *self.rig_owner, owner_pgid=os.getpgrp(), directory=self.directory)
        except (Held, OSError, ValueError) as error:
            if made:
                try:
                    os.rmdir(self.rig)  # the empty dir this call made: nothing is left unrecorded
                except OSError:
                    pass
            raise SystemExit(f"refusing to start: the rig dir's cleanup record was lost and not written again: {error}")

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
        Call after launch, and again after a relaunch: it arms end() again. A record that cannot be written
        raises (after launch, so the script's `finally` tears the rig down); a daemon that exited before its
        start time could be read is logged, and its home is left to the rig dir's record and the reaper."""
        self.done = False
        self.teardown.done = False
        homes = build_homes(self.bundle_id)
        for pid, home in self._daemons():
            if not homes.fullmatch(home):
                self.log(f"teardown: acpmux {pid} runs in {home}, not a home of {self.bundle_id}; not recorded")
                continue
            start = process_start(pid)
            if start is None:
                self.log(f"teardown: acpmux {pid} in {home} exited before it could be recorded")
                continue
            if self.homes.get(home) == (pid, start):
                continue
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
            if remove_recorded(home, pid, start, self.directory):
                self.log(f"teardown: removed acpmux home {home}")
            else:
                self.log(f"teardown: {home} kept with its record (re-registered, or not removable)")
        if remove_rig:
            left = self.teardown.processes()
            if left:
                self.log(f"teardown: {len(left)} processes of the bundle still run; the rig dir and its record are kept")
            elif getattr(self, "rig_owner", None):
                with RegistryLock(self.directory):
                    if not owned(read_record(self.rig, self.directory), *self.rig_owner):
                        self.log(f"teardown: no record of this run names {self.rig}; kept")
                        return
                    shutil.rmtree(self.rig, ignore_errors=True)
                    if not os.path.exists(self.rig):
                        try:
                            os.unlink(record_file(self.rig, self.directory))
                        except FileNotFoundError:
                            pass
                        self.log(f"teardown: removed rig dir {self.rig}")
