from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "sri.py"
SPEC = importlib.util.spec_from_file_location("sri", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
sri = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sri)


class SRIParserTests(unittest.TestCase):
    def test_returns_every_entry_for_the_strongest_supported_algorithm(self) -> None:
        algorithm, entries = sri.strongest_sri_entries(
            "sha256-first sha512-one sha384-middle sha512-two"
        )

        self.assertEqual(algorithm, "sha512")
        self.assertEqual(entries, frozenset(("sha512-one", "sha512-two")))

    def test_rejects_unusable_integrity_lists(self) -> None:
        for integrity in ("", "missing-separator trailing-", "md5-unsupported"):
            with self.subTest(integrity=integrity), self.assertRaises(sri.SRIError):
                sri.strongest_sri_entries(integrity)


if __name__ == "__main__":
    unittest.main()
