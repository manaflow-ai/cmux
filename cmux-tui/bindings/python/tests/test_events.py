from __future__ import annotations

import unittest

from cmux.client import _parse_event


class EventTests(unittest.TestCase):
    def test_title_changed_decodes_authoritative_title(self) -> None:
        event = _parse_event(
            {
                "event": "title-changed",
                "surface": 7,
                "title": "build logs",
            }
        )

        self.assertEqual(event.event, "title-changed")
        self.assertEqual(event.surface, 7)
        self.assertEqual(event.title, "build logs")

    def test_legacy_title_changed_keeps_title_optional(self) -> None:
        event = _parse_event({"event": "title-changed", "surface": 7})

        self.assertEqual(event.event, "title-changed")
        self.assertEqual(event.surface, 7)
        self.assertIsNone(event.title)


if __name__ == "__main__":
    unittest.main()
