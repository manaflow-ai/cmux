import os
import json
import unittest
from uuid import UUID
from pathlib import Path
from unittest.mock import patch

from cmux import (
    CmuxClient,
    EnsureTerminalEnvironment,
    ProtocolError,
    TopologyOperation,
    TopologyResnapshotReason,
)
from cmux.client import _default_socket_path, default_socket_path
from cmux.topology import (
    parse_resnapshot_required,
    parse_topology_delta,
    parse_topology_snapshot,
    validate_topology_delta,
)


class ProtocolTests(unittest.TestCase):
    def test_protocol_v8_shared_vectors_decode_topology_and_recovery(self) -> None:
        vectors = json.loads(
            (Path(__file__).parents[2] / "conformance" / "topology-v8.json").read_text()
        )
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = None
        client._identity = None
        client._request = lambda command, **_params: vectors[command]
        identity = client.identify()
        self.assertEqual(identity.topology_revision, 47)
        self.assertEqual(identity.topology_cursor.revision, 41)
        ping = client.ping()
        self.assertEqual(ping.topology_revision, 47)
        self.assertEqual(ping.canonical_topology_revision, 41)
        snapshot = parse_topology_snapshot(vectors["snapshot"])
        self.assertEqual(snapshot.revision, 41)
        self.assertEqual(snapshot.topology.workspaces[0].screens[0].panes[0].tabs[0].id, 4)
        delta = parse_topology_delta(vectors["delta"])
        self.assertEqual(delta.operation, TopologyOperation.WORKSPACE_RENAMED)
        self.assertIsNone(validate_topology_delta(snapshot.cursor, delta))
        self.assertEqual(
            [parse_resnapshot_required(item).reason for item in vectors["resnapshot_results"]],
            [
                TopologyResnapshotReason.STALE_DAEMON,
                TopologyResnapshotReason.STALE_SESSION,
                TopologyResnapshotReason.REVISION_AHEAD,
                TopologyResnapshotReason.HISTORY_GAP,
                TopologyResnapshotReason.REPLAY_TOO_LARGE,
            ],
        )
        slow = parse_resnapshot_required(vectors["slow_consumer_event"])
        self.assertEqual(slow.reason, TopologyResnapshotReason.SLOW_CONSUMER)
        self.assertIsNone(slow.current_revision)

    def test_legacy_resize_response_defaults_to_accepted(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {}

        self.assertTrue(client.resize_surface(7, 80, 24).accepted)

    def test_resize_response_preserves_reservation_identity(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {"accepted": True, "reservation_id": 41}

        self.assertEqual(client.resize_surface(7, 80, 24).reservation_id, 41)

    def test_process_info_decodes_argv_and_canonical_tty(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {
            "pid": 42,
            "command": ["/bin/zsh", "-l"],
            "cwd": "/tmp",
            "tty": "/dev/ttys004",
        }

        result = client.process_info(7)
        self.assertEqual(result.pid, 42)
        self.assertEqual(result.command, ["/bin/zsh", "-l"])
        self.assertEqual(result.cwd, "/tmp")
        self.assertEqual(result.tty, "/dev/ttys004")

    def test_process_info_rejects_legacy_joined_command(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {
            "pid": 42,
            "command": "/bin/zsh -l",
            "cwd": None,
            "tty": None,
        }

        with self.assertRaisesRegex(ProtocolError, "argv array"):
            client.process_info(7)

    def test_ensure_terminal_sends_wait_policy_and_decodes_stable_placement(self) -> None:
        workspace_uuid = UUID("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        surface_uuid = UUID("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
        captured = {}
        client = CmuxClient.__new__(CmuxClient)

        def request(_cmd, **params):
            captured.update({"cmd": _cmd, **params})
            return {
                "created": True,
                "workspace": 1,
                "workspace_uuid": str(workspace_uuid),
                "screen": 2,
                "screen_uuid": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                "pane": 3,
                "pane_uuid": "ffffffff-ffff-4fff-8fff-ffffffffffff",
                "surface": 4,
                "surface_uuid": str(surface_uuid),
            }

        client._request = request
        result = client.ensure_terminal(
            workspace_uuid,
            surface_uuid,
            80,
            24,
            argv=["/bin/zsh", "-l"],
            env=[EnsureTerminalEnvironment("CMUX_TEST", "1")],
            wait_after_command=True,
        )

        self.assertTrue(result.created)
        self.assertEqual(result.surface_uuid, surface_uuid)
        self.assertEqual(captured["wait_after_command"], True)
        self.assertEqual(captured["env"], [{"name": "CMUX_TEST", "value": "1"}])

    def test_reparent_terminal_decodes_stable_placement(self) -> None:
        workspace_uuid = UUID("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        surface_uuid = UUID("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
        captured = {}
        client = CmuxClient.__new__(CmuxClient)

        def request(_cmd, **params):
            captured.update({"cmd": _cmd, **params})
            return {
                "moved": True,
                "workspace": 1,
                "workspace_uuid": str(workspace_uuid),
                "screen": 2,
                "screen_uuid": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                "pane": 3,
                "pane_uuid": "ffffffff-ffff-4fff-8fff-ffffffffffff",
                "surface": 4,
                "surface_uuid": str(surface_uuid),
            }

        client._request = request
        result = client.reparent_terminal(surface_uuid, workspace_uuid)
        self.assertTrue(result.moved)
        self.assertEqual(result.surface_uuid, surface_uuid)
        self.assertEqual(captured["cmd"], "reparent-terminal")

    def test_attach_rejects_protocols_newer_than_eight_even_with_opt_in(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 9
        client.allow_protocol_v6_attach = True

        with self.assertRaisesRegex(ProtocolError, "maximum supported is 8"):
            client.attach_surface(1)

    def test_default_socket_path_prefers_xdg_and_ignores_empty_values(self) -> None:
        with patch.dict(
            os.environ,
            {"XDG_RUNTIME_DIR": "/xdg-runtime", "TMPDIR": "/tmp-runtime"},
            clear=False,
        ):
            self.assertTrue(default_socket_path("main").startswith("/xdg-runtime/"))
        with patch.dict(
            os.environ,
            {"XDG_RUNTIME_DIR": "", "TMPDIR": "/tmp-runtime"},
            clear=False,
        ):
            self.assertTrue(default_socket_path("main").startswith("/tmp-runtime/"))

    def test_darwin_default_socket_path_accepts_103_bytes_and_falls_back_at_104(self) -> None:
        base = "/tmp/runtime"
        uid = "42"
        empty_session = os.path.join(base, f"cmux-tui-{uid}", ".sock")
        session = "s" * (103 - len(os.fsencode(empty_session)))

        accepted = _default_socket_path(base, uid, session, True)
        self.assertEqual(len(os.fsencode(accepted)), 103)
        self.assertTrue(accepted.startswith(base + "/"))

        fallback = _default_socket_path(base, uid, session + "s", True)
        self.assertTrue(fallback.startswith(f"/tmp/cmux-tui-{uid}/"))
        self.assertNotEqual(fallback, os.path.join(base, f"cmux-tui-{uid}", f"{session}s.sock"))


if __name__ == "__main__":
    unittest.main()
