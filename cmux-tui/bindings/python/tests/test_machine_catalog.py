from __future__ import annotations

import unittest
import json

from cmux import Client, MachineId, aio
from support import UnixJsonServer, send_frame

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
        self.assertIsNone(decoded.platform)
        self.assertEqual(decoded.capabilities, ())
        nullable = _machine_snapshot(self.snapshot(platform={"os": None, "arch": None}))
        self.assertIsNone(nullable.platform.os)
        self.assertIsNone(nullable.platform.arch)

    def test_malformed_metadata_and_unknown_siblings_remain_refused(self):
        for patch in ({"platform": 1}, {"platform": {"os": 1}},
                      {"platform": {"os": "linux", "path": "/private"}},
                      {"capabilities": "terminal"}, {"capabilities": None}, {"capabilities": [1]},
                      {"command": "echo bad"}):
            with self.subTest(patch=patch), self.assertRaises(ProtocolError):
                _machine_snapshot(self.snapshot(**patch))


class MachineCatalogWireTests(unittest.TestCase):
    def test_cmux_next_machine_sdk_catalog_opt_in_keeps_defaults_and_owner_route(self):
        seen = []
        owner_id = "machine_" + "a" * 32
        def serve(connection, _index):
            source = connection.makefile("rb")
            for line in source:
                request = json.loads(line)
                seen.append(request)
                owner = {"id": owner_id, "name": "owner", "origin": "local", "status": "running",
                         "connectable": True, "deleted": False, "recoverable": False}
                if request["params"].get("catalog") is True:
                    owner.update(platform={"os": "linux"}, capabilities=["terminal"])
                result = [owner] if request["operation"] == "machine.list" else owner
                send_frame(connection, {"protocol": "cmux.protocol/2", "type": "response", "id": request["id"], "ok": True, "result": result})
        with UnixJsonServer(serve) as peer:
            with Client(socket_path=peer.path) as client:
                client.list_machines()
                client.list_machines(catalog=True)
                client.list_machines(catalog=False)
                owner = client.machine(MachineId(owner_id))
                for invalid in (1, "true", None):
                    with self.subTest(catalog=invalid), self.assertRaises(TypeError):
                        client.list_machines(catalog=invalid)
                    with self.subTest(catalog=invalid), self.assertRaises(TypeError):
                        owner.refresh(catalog=invalid)
                owner.refresh()
                rich = owner.refresh(catalog=True)
                owner.refresh(catalog=False)
        self.assertEqual(len(seen), 6)
        for index, request in enumerate(seen):
            expected = {} if index < 3 else {"machine": owner_id}
            if index in (1, 4): expected["catalog"] = True
            self.assertEqual(request["params"], expected, f"wire request {index}")
            self.assertNotIn("idempotency_key", request)
        self.assertEqual(rich.platform.os, "linux")


class AsyncMachineCatalogWireTests(unittest.IsolatedAsyncioTestCase):
    async def test_cmux_next_machine_sdk_catalog_opt_in_uses_the_shared_async_path(self):
        seen = []
        owner_id = "machine_" + "a" * 32
        def serve(connection, _index):
            for line in connection.makefile("rb"):
                request = json.loads(line)
                seen.append(request)
                owner = {"id": owner_id, "name": "owner", "origin": "local", "status": "running",
                         "connectable": True, "deleted": False, "recoverable": False}
                result = [owner] if request["operation"] == "machine.list" else owner
                send_frame(connection, {"protocol": "cmux.protocol/2", "type": "response", "id": request["id"], "ok": True, "result": result})
        with UnixJsonServer(serve) as peer:
            async with aio.Client(socket_path=peer.path) as client:
                owner = (await client.list_machines())[0]
                await client.list_machines(catalog=True)
                await owner.refresh(catalog=True)
                await owner.refresh(catalog=False)
        self.assertEqual([request["params"] for request in seen], [
            {}, {"catalog": True}, {"machine": owner_id, "catalog": True}, {"machine": owner_id}])
