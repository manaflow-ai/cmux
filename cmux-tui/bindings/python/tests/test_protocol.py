import unittest
from unittest.mock import patch

from cmux import CmuxClient, ProtocolError
from cmux.client import IdentifyResult, Layout, _parse_tree


class ProtocolTests(unittest.TestCase):
    def test_identify_result_preserves_positional_artifact_revisions(self) -> None:
        result = IdentifyResult(
            "cmux-tui", "0.1.2", 7, "main", 42, "cmux-sha", "ghostty-sha"
        )

        self.assertEqual(result.build_commit, "cmux-sha")
        self.assertEqual(result.ghostty_commit, "ghostty-sha")
        self.assertEqual(result.capabilities, ())

    def test_identify_and_ping_preserve_artifact_revisions(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        responses = {
            "identify": {
                "app": "cmux-tui",
                "version": "0.1.2",
                "protocol": 7,
                "session": "main",
                "pid": 42,
                "build_commit": "cmux-sha",
                "ghostty_commit": "ghostty-sha",
            },
            "ping": {
                "ok": True,
                "version": "0.1.2",
                "protocol": 7,
                "build_commit": "cmux-sha",
                "ghostty_commit": "ghostty-sha",
            },
        }
        client._request = lambda command, **_params: responses[command]

        self.assertEqual(client.identify().build_commit, "cmux-sha")
        self.assertEqual(client.identify().ghostty_commit, "ghostty-sha")
        self.assertEqual(client.ping().build_commit, "cmux-sha")
        self.assertEqual(client.ping().ghostty_commit, "ghostty-sha")

    def test_artifact_revisions_are_optional_for_older_servers(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {
            "app": "cmux-tui",
            "version": "0.1.2",
            "protocol": 7,
            "session": "main",
            "pid": 42,
        }

        result = client.identify()
        self.assertIsNone(result.build_commit)
        self.assertIsNone(result.ghostty_commit)

    def test_legacy_resize_response_defaults_to_accepted(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {}

        self.assertTrue(client.resize_surface(7, 80, 24).accepted)

    def test_resize_response_preserves_reservation_identity(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {"accepted": True, "reservation_id": 41}

        self.assertEqual(client.resize_surface(7, 80, 24).reservation_id, 41)

    def test_attach_accepts_newer_additive_protocols_with_opt_in(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 10
        client.allow_protocol_v6_attach = True

        with patch("cmux.client.AttachStream", return_value=object()) as attach:
            client.attach_surface(1)

        attach.assert_called_once_with(client, {"cmd": "attach-surface", "surface": 1})

    def test_attach_rejects_partial_initial_size_locally(self) -> None:
        client = CmuxClient.__new__(CmuxClient)

        with self.assertRaisesRegex(
            ValueError, "attach-surface cols and rows must be supplied together"
        ):
            client.attach_surface(1, cols=80)

    def test_workspace_registry_fields_and_placements(self) -> None:
        tree = _parse_tree({
            "workspace_revision": 4,
            "pane_revision": 7,
            "workspaces": [{"id": 1, "key": "stable", "name": "one", "active": True, "screens": []}],
        })
        self.assertEqual(tree.workspace_revision, 4)
        self.assertEqual(tree.pane_revision, 7)
        self.assertEqual(tree.workspaces[0].key, "stable")
        self.assertIsNone(_parse_tree({"workspaces": []}).pane_revision)

        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 7
        client._capabilities = {"workspace-registry-v1"}
        client._request = lambda cmd, **_params: (
            {"workspace": 1, "key": "stable", "index": 0, "workspace_revision": 5}
            if cmd == "create-workspace"
            else {"surface": 5, "pane": 4, "screen": 3, "workspace": 1, "key": "stable"}
        )
        self.assertEqual(client.create_workspace().workspace_revision, 5)
        self.assertEqual(client.create_terminal(key="stable").surface, 5)

        client._request = lambda _cmd, **_params: {
            "workspace": 1,
            "key": "stable",
            "workspace_revision": 6,
        }
        self.assertEqual(client.close_workspace_registry(key="stable").workspace_revision, 6)
        self.assertEqual(client.rename_workspace_registry("two", key="stable").workspace_revision, 6)
        self.assertEqual(client.move_workspace_registry(0, key="stable").workspace_revision, 6)

    def test_workspace_registry_selectors_reject_missing_and_empty_keys_locally(self) -> None:
        client = CmuxClient.__new__(CmuxClient)

        with self.assertRaisesRegex(ValueError, "workspace or key is required"):
            client.create_terminal()
        with self.assertRaisesRegex(ValueError, "workspace or key is required"):
            client.close_workspace_registry(key="  ")
    def test_new_pane_rejects_servers_older_than_protocol_nine(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 8

        with self.assertRaisesRegex(ProtocolError, "new-pane requires protocol 9"):
            client.new_pane(1)

    def test_set_split_ratio_rejects_servers_older_than_protocol_eight(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 7

        with self.assertRaisesRegex(ProtocolError, "set-split-ratio requires protocol 8"):
            client.set_split_ratio(1, 0.5)

    def test_set_split_ratio_accepts_newer_additive_protocols(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 9
        requests = []
        client._request = lambda command, **params: requests.append((command, params)) or {}

        client.set_split_ratio(1, 0.5)

        self.assertEqual(requests, [("set-split-ratio", {"split": 1, "ratio": 0.5})])

    def test_layout_preserves_protocol_seven_positional_constructor_order(self) -> None:
        first = Layout("leaf", 1)
        second = Layout("leaf", 2)

        layout = Layout("split", None, "right", 0.5, first, second)

        self.assertEqual(layout.dir, "right")
        self.assertEqual(layout.ratio, 0.5)
        self.assertEqual(layout.a, first)
        self.assertEqual(layout.b, second)
        self.assertIsNone(layout.split)


if __name__ == "__main__":
    unittest.main()
