import unittest

from cmux import CmuxClient, ProtocolError


class ProtocolTests(unittest.TestCase):
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

    def test_attach_rejects_protocols_newer_than_seven_even_with_opt_in(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 8
        client.allow_protocol_v6_attach = True

        with self.assertRaisesRegex(ProtocolError, "maximum supported is 7"):
            client.attach_surface(1)


if __name__ == "__main__":
    unittest.main()
