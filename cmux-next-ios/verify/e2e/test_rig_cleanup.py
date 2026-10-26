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

    def test_end_stops_the_bundle_then_removes_the_dirs_and_their_records(self):
        c, fake = self.cleanup_with({self.gone_pid(): self.app_home, self.gone_pid(): self.chief_home})
        c.register_rig()
        c.register_daemons()
        self.assertEqual(len(self.records()), 3)
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


if __name__ == "__main__":
    unittest.main()
