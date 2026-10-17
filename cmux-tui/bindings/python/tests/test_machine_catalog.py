from __future__ import annotations

import unittest

from cmux import ProtocolError
from cmux.resources import _machine_snapshot


class MachineCatalogTests(unittest.TestCase):
    def snapshot(self, **patch):
        return {"id": "machine_" + "a" * 32, "name": "build server", "origin": "local",
                "status": "running", "connectable": True, "deleted": False,
                "recoverable": False, **patch}

    def test_native_platform_metadata_and_remote_origins_survive_decoding(self):
        for origin in ("local", "cloud", "ssh", "server"):
            with self.subTest(origin=origin):
                decoded, failure = None, None
                try:
                    decoded = _machine_snapshot(self.snapshot(origin=origin,
                        platform={"os": "linux", "arch": "aarch64"},
                        capabilities=["terminal", "agent_session"]))
                except ProtocolError as error:
                    failure = str(error)
                self.assertIsNone(failure, "the machine contract must decode: " + str(failure))
                self.assertEqual(decoded.origin, origin)
                self.assertEqual(decoded.platform.os, "linux")
                self.assertEqual(decoded.platform.arch, "aarch64")
                self.assertEqual(tuple(decoded.capabilities), ("terminal", "agent_session"))

    def test_existing_local_records_keep_their_identity_and_state(self):
        decoded = _machine_snapshot(self.snapshot())
        self.assertEqual(str(decoded.id), "machine_" + "a" * 32)
        self.assertEqual(decoded.origin, "local")
        self.assertTrue(decoded.connectable)

    def test_malformed_metadata_and_unknown_siblings_remain_refused(self):
        for patch in ({"platform": 1}, {"platform": {"os": 1}},
                      {"platform": {"os": "linux", "path": "/private"}},
                      {"capabilities": "terminal"}, {"capabilities": [1]},
                      {"command": "echo bad"}):
            with self.subTest(patch=patch), self.assertRaises(ProtocolError):
                _machine_snapshot(self.snapshot(**patch))
