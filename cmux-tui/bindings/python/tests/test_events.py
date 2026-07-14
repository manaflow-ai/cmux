from __future__ import annotations

import unittest

from cmux.client import _Stream, _parse_event


class _FakeConnection:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


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

    def test_overflow_exposes_recovery_fields(self) -> None:
        event = _parse_event(
            {
                "event": "overflow",
                "error": "subscriber fell behind",
                "scope": "surface",
                "surface": 7,
            }
        )

        self.assertEqual(event.event, "overflow")
        self.assertEqual(event.error, "subscriber fell behind")
        self.assertEqual(event.scope, "surface")
        self.assertEqual(event.surface, 7)

    def test_stream_yields_buffered_overflow_once_then_stops(self) -> None:
        connection = _FakeConnection()
        stream = _Stream.__new__(_Stream)
        stream._conn = connection
        stream._queue = [_parse_event({"event": "overflow", "error": "fell behind"})]
        stream._closed = False

        self.assertEqual(next(stream).event, "overflow")
        self.assertTrue(connection.closed)
        with self.assertRaises(StopIteration):
            next(stream)


if __name__ == "__main__":
    unittest.main()
