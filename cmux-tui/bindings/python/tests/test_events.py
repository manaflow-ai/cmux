from __future__ import annotations

import base64
import unittest

from cmux.raw._generated.codec import decode_event


class EventTests(unittest.TestCase):
    def test_byte_attachment_payload_decodes_without_precision_loss(self) -> None:
        payload = b"\x00cmux\xff"
        event = decode_event(
            {
                "event": "output",
                "surface": 2**63 + 1,
                "data": base64.b64encode(payload).decode("ascii"),
            }
        )

        self.assertEqual(event.surface, 2**63 + 1)
        self.assertEqual(event.bytes_data, payload)

    def test_nullable_event_field_remains_none(self) -> None:
        event = decode_event(
            {
                "event": "notification",
                "notification": 17,
                "title": "build",
                "body": "done",
                "level": "info",
                "surface": None,
            }
        )

        self.assertIsNone(event.surface)
        self.assertEqual(event.title, "build")


if __name__ == "__main__":
    unittest.main()
