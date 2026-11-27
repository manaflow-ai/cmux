from __future__ import annotations

import base64
import unittest

from cmux.raw import CmuxClient, MISSING
from cmux.raw._generated.client import GeneratedClientMixin


class RecordingClient(GeneratedClientMixin):
    def __init__(self) -> None:
        self.calls = []

    def _invoke_command(self, command, request):
        self.calls.append(("command", command, request))
        return request

    def _open_command_stream(self, command, request):
        self.calls.append(("stream", command, request))
        return request


class ConsumerTests(unittest.TestCase):
    def test_send_accepts_text_and_raw_bytes(self) -> None:
        client = RecordingClient()

        request = client.send(7, text="hello", bytes_data=b"\x00\xff")

        self.assertEqual(client.calls[0][1], "send")
        self.assertEqual(request.surface, 7)
        self.assertEqual(request.text, "hello")
        self.assertEqual(
            request.bytes_data,
            base64.b64encode(b"\x00\xff").decode("ascii"),
        )

    def test_generated_stream_methods_keep_missing_fields_absent(self) -> None:
        client = RecordingClient()

        request = client.attach_surface(9, mode="render")

        self.assertEqual(client.calls[0][:2], ("stream", "attach-surface"))
        self.assertEqual(request.surface, 9)
        self.assertEqual(request.mode, "render")
        self.assertIs(request.cols, MISSING)
        self.assertIs(request.rows, MISSING)

    def test_attachment_and_delta_helpers_select_wire_modes(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        calls = []
        client.attach_surface = (
            lambda surface, **params: calls.append(("attach", surface, params)) or params
        )
        client.subscribe = (
            lambda **params: calls.append(("subscribe", params)) or params
        )

        self.assertEqual(client.attach_bytes(1)["mode"], "bytes")
        self.assertEqual(client.attach_render(2)["mode"], "render")
        self.assertEqual(client.attach_browser(3)["mode"], "bytes")
        self.assertEqual(client.subscribe_deltas()["tree_events"], "deltas")


if __name__ == "__main__":
    unittest.main()
