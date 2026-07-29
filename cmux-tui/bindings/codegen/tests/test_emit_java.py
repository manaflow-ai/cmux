from __future__ import annotations

import re
import unittest
from pathlib import Path

from codegen.emit_java import emit
from codegen.ir import load_ir


LIVE_SCHEMA = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"


class JavaEmitterTests(unittest.TestCase):
    def test_raw_sources_never_import_support_types_from_parent_package(self) -> None:
        generated = emit(load_ir(LIVE_SCHEMA))

        for path, source in generated.items():
            with self.subTest(path=path):
                self.assertIn("package com.cmux.raw;", source)
                parent_imports = re.findall(
                    r"^import com\.cmux\.(?!raw\.)[^;]+;$",
                    source,
                    flags=re.MULTILINE,
                )
                self.assertEqual([], parent_imports)

        agent_record = generated["AgentRecord.java"]
        self.assertIn("implements WireValue", agent_record)
        self.assertNotIn("import com.cmux.WireValue;", agent_record)


if __name__ == "__main__":
    unittest.main()
