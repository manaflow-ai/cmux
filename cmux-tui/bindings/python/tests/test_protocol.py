import unittest

from cmux import CmuxClient, ProtocolError
from cmux.client import _parse_tree


class ProtocolTests(unittest.TestCase):
    def test_legacy_resize_response_defaults_to_accepted(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {}

        self.assertTrue(client.resize_surface(7, 80, 24).accepted)

    def test_resize_response_preserves_reservation_identity(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._request = lambda _command, **_params: {"accepted": True, "reservation_id": 41}

        self.assertEqual(client.resize_surface(7, 80, 24).reservation_id, 41)

    def test_attach_rejects_protocols_newer_than_seven_even_with_opt_in(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 8
        client.allow_protocol_v6_attach = True

        with self.assertRaisesRegex(ProtocolError, "maximum supported is 7"):
            client.attach_surface(1)

    def test_workspace_registry_fields_and_placements(self) -> None:
        tree = _parse_tree({
            "workspace_revision": 4,
            "workspaces": [{"id": 1, "key": "stable", "name": "one", "active": True, "screens": []}],
        })
        self.assertEqual(tree.workspace_revision, 4)
        self.assertEqual(tree.workspaces[0].key, "stable")

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


if __name__ == "__main__":
    unittest.main()
