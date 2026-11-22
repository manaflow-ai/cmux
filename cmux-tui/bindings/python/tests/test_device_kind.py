"""Shared-sizing device kinds: linux and windows are known, others are unknown."""

from __future__ import annotations

import unittest

from cmux.raw._generated import models
from cmux.raw._generated.codec import ProtocolDecodeError, decode_command_result


def _state(device_kind):
    return {
        "state": {
            "generation": 1,
            "cols": 80,
            "rows": 24,
            "reason": "latest",
            "owners": ["c1"],
            "policy": {"mode": "latest", "priority": [], "fixed": None},
            "participants": [
                {
                    "id": "c1",
                    "user_id": "u1",
                    "display_name": None,
                    "device_kind": device_kind,
                    "device_name": None,
                    "device_id": None,
                    "via": None,
                    "viewport": None,
                    "counts": True,
                    "counts_override": None,
                    "priority_key": "u1/x",
                }
            ],
        },
        "self_participant": "c1",
    }


def _kind(result):
    participant = result.state.participants[0]
    return participant.device_kind


class DeviceKindTests(unittest.TestCase):
    def test_linux_and_windows_decode_as_their_own_kinds(self) -> None:
        for raw in ("mac", "iphone", "ipad", "tui", "browser", "linux", "windows", "unknown"):
            with self.subTest(raw=raw):
                kind = _kind(decode_command_result("get-size-state", _state(raw)))
                self.assertEqual(models.SizeDeviceKind(raw), kind)

    def test_an_unknown_device_kind_decodes_as_a_generic_client(self) -> None:
        kind = _kind(decode_command_result("get-size-state", _state("quantum")))
        self.assertEqual(models.SizeDeviceKind.UNKNOWN, kind)

    def test_a_non_string_device_kind_is_still_a_decode_error(self) -> None:
        with self.assertRaises(ProtocolDecodeError):
            decode_command_result("get-size-state", _state(7))


if __name__ == "__main__":
    unittest.main()
