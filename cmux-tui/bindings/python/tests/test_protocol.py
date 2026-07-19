import unittest
from unittest.mock import patch

from cmux import CmuxClient, ProtocolError
from cmux.client import Layout


class ProtocolTests(unittest.TestCase):
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
