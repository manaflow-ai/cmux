#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for license_match.py: shipped texts must satisfy the concluded SPDX
expression (one OR branch with a matching text for every license in it)."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import license_match as lm  # noqa: E402

MIT = ("Permission is hereby granted, free of charge, to any person obtaining a copy of this software. "
       "The above copyright notice and this permission notice shall be included in all copies.")
APACHE = ("Apache License\n Version 2.0, January 2004\n TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION\n"
          " 2. Grant of Copyright License.")
BSD3 = ("Redistribution and use in source and binary forms, with or without modification, are permitted. "
        "Redistributions of source code must retain the above copyright notice. Neither the name of Tailscale.")
ZLIB = ("This software is provided 'as-is', without any express or implied warranty. "
        "2. Altered source versions must be plainly marked as such.")
ISC = ("// Permission to use, copy, modify, and/or distribute this software for any\n"
       "// purpose with or without fee is hereby granted, provided that the above\n"
       "// copyright notice and this permission notice appear in all copies.")


class ExpressionTest(unittest.TestCase):
    def test_branches(self) -> None:
        self.assertEqual(lm.branches("MIT OR Apache-2.0"), [["MIT"], ["Apache-2.0"]])
        self.assertEqual(lm.branches("(MIT OR Apache-2.0) AND Unicode-3.0"), [["MIT", "Unicode-3.0"], ["Apache-2.0", "Unicode-3.0"]])
        self.assertEqual(lm.branches("Apache-2.0 WITH LLVM-exception OR MIT"), [["Apache-2.0 WITH LLVM-exception"], ["MIT"]])
        with self.assertRaises(lm.ExpressionError):
            lm.branches("(MIT OR")

    def test_iroh_bsd3_only_fails(self) -> None:
        self.assertIsNotNone(lm.expression_problem("MIT OR Apache-2.0", [BSD3]))
        self.assertIsNone(lm.expression_problem("MIT OR Apache-2.0", [BSD3, MIT]))

    def test_and_needs_every_license(self) -> None:
        self.assertIsNotNone(lm.expression_problem("Apache-2.0 AND ISC", [APACHE]))
        self.assertIsNone(lm.expression_problem("Apache-2.0 AND ISC", [APACHE, ISC]))

    def test_or_needs_one_complete_branch(self) -> None:
        self.assertIsNone(lm.expression_problem("Zlib OR Apache-2.0 OR MIT", [ZLIB]))
        self.assertIsNotNone(lm.expression_problem("(MIT AND Zlib) OR Apache-2.0", [MIT]))

    def test_unknown_id_fails_and_licenseref_needs_a_file(self) -> None:
        problem = lm.expression_problem("NoSuchLicense-1.0", [MIT])
        self.assertIn("unknown license id", problem)
        self.assertIsNone(lm.expression_problem("LicenseRef-foo-1.0", ["custom terms"]))
        self.assertIsNotNone(lm.expression_problem("LicenseRef-foo-1.0", []))

    def test_a_pointer_text_is_not_a_license(self) -> None:
        # The objc2 LICENSE.md and siphasher COPYING only point to the terms.
        pointer = "Licensed under the Apache License, Version 2.0 <LICENSE-APACHE> or the MIT license <http://opensource.org/licenses/MIT>, at your option."
        self.assertIsNotNone(lm.expression_problem("MIT OR Apache-2.0", [pointer]))

    def test_mit_and_mit0_differ(self) -> None:
        mit0 = "Permission is hereby granted, free of charge, to any person obtaining a copy of this software, without restriction."
        self.assertIsNone(lm.expression_problem("MIT-0", [mit0]))
        self.assertIsNotNone(lm.expression_problem("MIT", [mit0]))


if __name__ == "__main__":
    unittest.main()
