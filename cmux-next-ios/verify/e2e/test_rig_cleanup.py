"""Unit tests for the rig teardown's records and removals (python3 -m unittest test_rig_cleanup, from this folder).

A stand-in TagTeardown lists the bundle's processes and records end(); a real `sleep` stands in
for a daemon that still runs. Nothing outside a temp HOME and registry is touched."""
import json
import os
import subprocess
import tempfile
import types
import unittest
from unittest import mock

import rig_cleanup

BUNDLE_ID = "com.cmuxterm.app.debug.cmux.mobile.e2e.a3713d4d"


class FakeTeardown:
    def __init__(self, app, daemons):
        self.bin = os.path.join(app, "Contents/Resources/bin")
        self.daemons = daemons  # pid -> ACPMUX_HOME
        self.left = []
        self.ended = 0
        self.done = False

    def install(self):
        pass

    def processes(self):
        if self.ended:
            return list(self.left)
        return [(pid, f"{self.bin}/acpmux daemon run --ready-fd 3") for pid in self.daemons]

    def end(self):
        self.ended += 1


class RigCleanupTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = os.path.realpath(tmp.name)
        patcher = mock.patch.dict(os.environ, {"HOME": self.home, "CMUX_CLEANUP_REGISTRY": os.path.join(self.home, "reg")})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.rig = os.path.join(self.home, "cmux-next-ios-e2e", "cmux-mobile-e2e-a3713d4d")
        self.app = os.path.join(self.rig, "mac", "cmux DEV cmux-mobile-e2e-a3713d4d.app")
        self.app_home = os.path.join(self.home, ".acpmux", "builds", BUNDLE_ID)
        self.chief_home = os.path.join(self.home, ".cmux", "chief", BUNDLE_ID, "acpmux")
        for d in (self.app, self.app_home, self.chief_home):
            os.makedirs(d)
        self.envs = {}
        fake_module = types.SimpleNamespace(procargs=lambda pid: ([], self.envs.get(pid, {})))
        patcher = mock.patch.object(rig_cleanup, "_teardown_module", return_value=fake_module)
        patcher.start()
        self.addCleanup(patcher.stop)

    def records(self):
        directory = rig_cleanup.registry_dir()
        if not os.path.isdir(directory):
            return {}
        out = {}
        for name in os.listdir(directory):
            if name.endswith(".json"):
                with open(os.path.join(directory, name)) as f:
                    rec = json.load(f)
                out[rec["path"]] = (name, rec)
        return out

    def cleanup_with(self, daemons):
        self.envs = {pid: {"ACPMUX_HOME": home} for pid, home in daemons.items()}
        fake = FakeTeardown(self.app, daemons)
        return rig_cleanup.RigCleanup(self.rig, self.app, BUNDLE_ID, log=lambda _l: None, teardown=fake), fake

    def gone_pid(self):
        p = subprocess.Popen(["true"])
        p.wait()
        return p.pid

    def test_records_use_the_agreed_format(self):
        c, _ = self.cleanup_with({})
        c.register_rig()
        name, rec = self.records()[self.rig]
        self.assertEqual(name, f"cmux-next-ios-e2e-{rig_cleanup.hashlib.sha256(self.rig.encode()).hexdigest()[:16]}.json")
        self.assertEqual(rec["schema"], "cleanup-registry/v1")
        self.assertEqual(rec["tool"], "cmux-next-ios-e2e")
        self.assertEqual((rec["kind"], rec["cleanup"], rec["max_age_hours"]), ("job", "trap", 12))
        self.assertEqual(rec["owner_pid"], os.getpid())
        self.assertIsInstance(rec["owner_start"], int)
        self.assertEqual(rec["host"], os.uname().nodename)
        rig_cleanup.unregister(self.rig)
        self.assertEqual(self.records(), {})

    def test_each_daemon_home_is_recorded_with_the_daemon_as_owner(self):
        sleeper = subprocess.Popen(["sleep", "30"])
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        c, _ = self.cleanup_with({sleeper.pid: self.app_home})
        c.register_daemons()
        rec = self.records()[self.app_home][1]
        self.assertEqual(rec["owner_pid"], sleeper.pid)
        self.assertEqual(rec["owner_start"], rig_cleanup.process_start(sleeper.pid))

    def sleeper(self):
        p = subprocess.Popen(["sleep", "30"])
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        return p

    def test_end_stops_the_bundle_then_removes_the_dirs_and_their_records(self):
        daemons = [self.sleeper(), self.sleeper()]
        c, fake = self.cleanup_with({daemons[0].pid: self.app_home, daemons[1].pid: self.chief_home})
        c.register_rig()
        c.register_daemons()
        self.assertEqual(len(self.records()), 3)
        for p in daemons:  # the teardown's shutdown ends them
            p.kill()
            p.wait()
        c.end()
        self.assertEqual(fake.ended, 1)
        for d in (self.app_home, self.chief_home, self.rig):
            self.assertFalse(os.path.exists(d), d)
        self.assertEqual(self.records(), {})
        self.assertTrue(os.path.isdir(os.path.join(self.home, ".cmux", "chief", BUNDLE_ID)))  # only its acpmux dir
        c.end()
        self.assertEqual(fake.ended, 1)  # once

    def test_a_daemon_that_still_runs_keeps_its_home_and_record(self):
        sleeper = subprocess.Popen(["sleep", "30"])
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        c, fake = self.cleanup_with({sleeper.pid: self.app_home})
        fake.left = [(sleeper.pid, "acpmux daemon run")]
        c.register_rig()
        c.end()
        self.assertTrue(os.path.isdir(self.app_home))
        self.assertIn(self.app_home, self.records())
        self.assertTrue(os.path.isdir(self.rig))  # a process of the bundle still runs
        self.assertIn(self.rig, self.records())

    def test_a_home_of_another_build_is_never_recorded_or_removed(self):
        shared = os.path.join(self.home, ".acpmux")
        other = os.path.join(self.home, ".acpmux", "builds", "com.cmuxterm.app.debug.other")
        os.makedirs(other)
        c, _ = self.cleanup_with({self.gone_pid(): shared, self.gone_pid(): other})
        c.register_daemons()
        self.assertEqual(self.records(), {})
        c.end(remove_rig=False)
        self.assertTrue(os.path.isdir(shared))
        self.assertTrue(os.path.isdir(other))

    def test_build_homes(self):
        homes = rig_cleanup.build_homes(BUNDLE_ID, self.home)
        self.assertTrue(homes.fullmatch(self.app_home))
        self.assertTrue(homes.fullmatch(self.chief_home))
        self.assertTrue(homes.fullmatch(self.app_home + "--cmux-mobile-e2e-x"))
        for path in (os.path.join(self.home, ".acpmux"), os.path.join(self.home, ".acpmux", "tags", "x"),
                     self.app_home + "x", self.app_home + "/sub", os.path.dirname(self.chief_home),
                     os.path.join(self.home, ".acpmux", "builds", "com.cmuxterm.app.debug.cmux")):
            self.assertFalse(homes.fullmatch(path), path)

    def test_a_live_owners_record_is_never_taken_over(self):
        sleeper = subprocess.Popen(["sleep", "30"])
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        rig_cleanup.register(self.rig, sleeper.pid, rig_cleanup.process_start(sleeper.pid))
        c, _ = self.cleanup_with({})
        with self.assertRaises(SystemExit):
            c.register_rig()
        self.assertEqual(self.records()[self.rig][1]["owner_pid"], sleeper.pid)
        # A dead owner's record is replaced.
        rig_cleanup.unregister(self.rig)
        rig_cleanup.register(self.rig, self.gone_pid(), 1)
        c.register_rig()
        self.assertEqual(self.records()[self.rig][1]["owner_pid"], os.getpid())

    def test_no_record_without_a_start_time(self):
        with self.assertRaises(ValueError):
            rig_cleanup.register(self.app_home, 12345, None)
        self.assertEqual(self.records(), {})
        c, _ = self.cleanup_with({self.gone_pid(): self.app_home})
        c.register_daemons()  # a daemon that already exited has no start time: nothing is written
        self.assertEqual(self.records(), {})

    def test_a_home_another_run_registered_since_is_kept(self):
        c, _ = self.cleanup_with({self.gone_pid(): self.app_home})
        c.homes[self.app_home] = (self.gone_pid(), 1)
        rig_cleanup.register(self.app_home, os.getpid(), rig_cleanup.process_start(os.getpid()))
        c.end(remove_rig=False)
        self.assertTrue(os.path.isdir(self.app_home))
        self.assertIn(self.app_home, self.records())

    def test_teardown_sends_daemon_shutdown_only_to_this_builds_homes(self):
        made = {}

        class Teardown:
            def __init__(self, app, **kwargs):
                made.update(kwargs, app=app)

        module = types.SimpleNamespace(TagTeardown=Teardown, procargs=lambda pid: None)
        with mock.patch.object(rig_cleanup, "_teardown_module", return_value=module):
            rig_cleanup.RigCleanup(self.rig, self.app, BUNDLE_ID).teardown
        ok = made["acpmux_home_ok"]
        self.assertTrue(ok(self.app_home))
        self.assertTrue(ok(self.chief_home))
        self.assertFalse(ok(os.path.join(self.home, ".acpmux")))
        self.assertFalse(ok(os.path.join(self.home, ".acpmux", "builds", "com.cmuxterm.app.debug.other")))

    def test_tag_teardown_skips_the_shutdown_of_a_refused_home(self):
        import sys
        sys.path.insert(0, os.path.join(rig_cleanup.REPO, "scripts", "cmux-next"))
        import tag_teardown
        acpmux = os.path.join(self.app, "Contents/Resources/bin/acpmux")
        lines, runs = [], []
        t = tag_teardown.TagTeardown(self.app, log=lines.append, acpmux_home_ok=lambda home: home == self.app_home)
        envs = {1: {"ACPMUX_HOME": self.app_home}, 2: {"ACPMUX_HOME": os.path.join(self.home, ".acpmux")}}
        with mock.patch.object(t, "processes", side_effect=[[(1, acpmux + " daemon run"), (2, acpmux + " daemon run")]]
                               + [[]] * 10), \
                mock.patch.object(t, "_environment", side_effect=lambda pid: envs[pid]), \
                mock.patch.object(t, "_run", side_effect=lambda argv, env=None, timeout=30: runs.append(env["ACPMUX_HOME"]) or "exit 0"), \
                mock.patch.object(tag_teardown.time, "sleep"):
            t.end()
        self.assertEqual(runs, [self.app_home])
        self.assertTrue(any("not a home of this tag" in line for line in lines))

    def test_a_home_or_rig_without_its_record_is_kept(self):
        c, _ = self.cleanup_with({})
        c.register_rig()
        c.homes[self.app_home] = (self.gone_pid(), 1)  # never recorded
        os.unlink(rig_cleanup.record_file(self.rig))
        c.end()
        self.assertTrue(os.path.isdir(self.app_home))
        self.assertTrue(os.path.isdir(self.rig))

    def test_a_live_group_holds_a_record(self):
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        rig_cleanup.register(self.rig, self.gone_pid(), 1, owner_pgid=sleeper.pid)
        with self.assertRaises(rig_cleanup.Held):
            rig_cleanup.register(self.rig, os.getpid(), rig_cleanup.process_start(os.getpid()))

    def test_a_record_that_cannot_be_written_stops_the_run(self):
        c, _ = self.cleanup_with({})
        with mock.patch.object(rig_cleanup, "_write", side_effect=OSError("disk full")):
            with self.assertRaises(SystemExit):
                c.register_rig()
        sleeper = self.sleeper()
        c, _ = self.cleanup_with({sleeper.pid: self.app_home})
        with mock.patch.object(rig_cleanup, "_write", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                c.register_daemons()

    def test_an_unreadable_process_table_counts_the_group_alive(self):
        failed = subprocess.CompletedProcess(["ps"], 1, stdout="", stderr="ps: failed")
        with mock.patch.object(rig_cleanup.os, "killpg"), \
                mock.patch.object(rig_cleanup.subprocess, "run", return_value=failed):
            self.assertTrue(rig_cleanup.group_alive(4242))

    def test_a_record_a_reaper_dropped_before_the_dir_existed_is_written_again(self):
        import shutil
        shutil.rmtree(self.rig)
        c, _ = self.cleanup_with({})
        real = rig_cleanup.register
        calls = []

        def register_then_drop(path, *args, **kwargs):
            out = real(path, *args, **kwargs)
            calls.append(path)
            if len(calls) == 1:  # the reconciler's "its dir is gone" between record and mkdir
                os.unlink(rig_cleanup.record_file(path))
            return out

        with mock.patch.object(rig_cleanup, "register", side_effect=register_then_drop):
            c.register_rig()
        self.assertTrue(os.path.isdir(self.rig))
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.records()[self.rig][1]["owner_pid"], os.getpid())

    def test_an_unreadable_record_is_never_taken_over(self):
        os.makedirs(rig_cleanup.registry_dir(), exist_ok=True)
        with open(rig_cleanup.record_file(self.rig), "w") as f:
            f.write("{not json")
        c, _ = self.cleanup_with({})
        with self.assertRaises(SystemExit):
            c.register_rig()
        with open(rig_cleanup.record_file(self.rig)) as f:
            self.assertEqual(f.read(), "{not json")

    def test_a_failed_rewrite_removes_the_empty_dir_it_made(self):
        import shutil
        shutil.rmtree(self.rig)
        c, _ = self.cleanup_with({})
        real = rig_cleanup.register
        calls = []

        def drop_then_fail(path, *args, **kwargs):
            calls.append(path)
            if len(calls) == 1:
                return real(path, *args, **kwargs) and os.unlink(rig_cleanup.record_file(path)) or path
            raise OSError("disk full")

        with mock.patch.object(rig_cleanup, "register", side_effect=drop_then_fail):
            with self.assertRaises(SystemExit):
                c.register_rig()
        self.assertFalse(os.path.exists(self.rig))

    def test_a_malformed_record_is_neither_taken_over_nor_obeyed(self):
        os.makedirs(rig_cleanup.registry_dir(), exist_ok=True)
        # What this tool writes is valid by its own reader.
        rig_cleanup.register(self.rig, os.getpid(), rig_cleanup.process_start(os.getpid()), owner_pgid=os.getpgrp())
        self.assertIsNotNone(rig_cleanup.read_record(self.rig, strict=True))
        rig_cleanup.unregister(self.rig)
        dead = self.gone_pid()
        for bad in ({"owner_pid": dead, "owner_start": 1},
                    {"schema": "cleanup-registry/v1", "tool": "other", "kind": "job", "path": self.rig,
                     "owner_pid": dead, "owner_start": 1},
                    {"schema": "cleanup-registry/v1", "tool": "cmux-next-ios-e2e", "kind": "job",
                     "path": "/elsewhere", "owner_pid": dead, "owner_start": 1}):
            with open(rig_cleanup.record_file(self.rig), "w") as f:
                json.dump(bad, f)
            with self.assertRaises(rig_cleanup.Held):
                rig_cleanup.register(self.rig, os.getpid(), rig_cleanup.process_start(os.getpid()))
        good = {"schema": "cleanup-registry/v1", "tool": "cmux-next-ios-e2e", "kind": "job", "path": self.app_home,
                "host": os.uname().nodename, "created": 1, "owner_pid": dead, "owner_start": 5,
                "cleanup": "trap", "max_age_hours": 12}
        self.assertEqual(rig_cleanup.invalid(good, self.app_home), "")
        self.assertEqual(rig_cleanup.invalid(dict(good, owner_pgid=7), self.app_home), "")
        for key, value in (("owner_start", 0), ("owner_start", -1), ("owner_start", 1.5), ("owner_start", float("inf")),
                           ("owner_pid", True), ("host", "elsewhere"), ("created", 0), ("max_age_hours", 0),
                           ("cleanup", "lru-cap"), ("owner_pgid", -2), ("owner_pgid", 0), ("created", 1.5),
                           ("reaper", "not-an-argv"), ("reaper", ["x"]), ("extra", 1), ("max_age_hours", 24)):
            self.assertNotEqual(rig_cleanup.invalid(dict(good, **{key: value}), self.app_home), "", key)
        for key in ("host", "created", "max_age_hours", "cleanup"):
            self.assertNotEqual(rig_cleanup.invalid({k: v for k, v in good.items() if k != key}, self.app_home), "", key)
        with open(rig_cleanup.record_file(self.app_home), "w") as f:
            json.dump(dict(good, owner_start=0), f)
        self.assertFalse(rig_cleanup.remove_recorded(self.app_home, dead, 0))
        self.assertTrue(os.path.isdir(self.app_home))
        # A malformed record naming this owner does not let the removal act.
        mine = {"owner_pid": dead, "owner_start": 1}
        with open(rig_cleanup.record_file(self.app_home), "w") as f:
            json.dump(mine, f)
        self.assertFalse(rig_cleanup.remove_recorded(self.app_home, dead, 1))
        self.assertTrue(os.path.isdir(self.app_home))


if __name__ == "__main__":
    unittest.main()
