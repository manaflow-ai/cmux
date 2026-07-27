from __future__ import annotations

import os
import unittest
from unittest import mock

from codegen.emit_rust import emit
from codegen.ir import load_ir_document

from support import schema_document


class RustEmitterTests(unittest.TestCase):
    def test_generated_layout_is_owned_and_does_not_require_rustfmt(self) -> None:
        ir = load_ir_document(schema_document())

        with mock.patch.dict(os.environ, {"PATH": ""}):
            first = emit(ir)
            second = emit(ir)

        self.assertEqual(first, second)
        self.assertEqual(
            set(first),
            {"commands.rs", "events.rs", "metadata.rs", "mod.rs", "types.rs"},
        )
        for path, source in first.items():
            with self.subTest(path=path):
                self.assertIsInstance(source, str)
                if path != "mod.rs":
                    self.assertIn(
                        "#[rustfmt::skip]\n",
                        source,
                        "complex generated items must keep emitter-owned layout",
                    )
                self.assertNotIn("#![rustfmt::skip]", source)


if __name__ == "__main__":
    unittest.main()
