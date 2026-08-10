from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

from codegen.emit_java import emit
from codegen.ir import load_ir


LIVE_SCHEMA = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"


class JavaEmitterTests(unittest.TestCase):
    def test_sdk_version_comes_from_java_package_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            manifest = Path(raw_directory) / "pom.xml"
            manifest.write_text(
                """\
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <version>9.8.7</version>
</project>
""",
                encoding="utf-8",
            )
            generated = emit(
                load_ir(LIVE_SCHEMA),
                version_manifest=manifest,
            )

        self.assertIn(
            'public static final String SDK_VERSION = "9.8.7";',
            generated["Protocol.java"],
        )

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
