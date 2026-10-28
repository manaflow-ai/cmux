"""A wire command name with a dot (``fs.delete``) must become a valid
identifier in every generated SDK.

The fs.* commands (cd59b9ec1e8) were the first dotted names in the schema; the
Python emitter split names only on ``-``/``_`` and wrote ``def fs.delete(``
and ``class Fs.deleteRequest:``, so the generated package did not parse.
"""

from __future__ import annotations

import ast
import copy
import re
import tempfile
import unittest
from pathlib import Path

from codegen.generate import available_languages, load_emitter
from codegen.ir import load_ir
from codegen.writer import render_files

from support import schema_document, write_schema


LIVE_SCHEMA = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"

DOTTED = "fs.delete"
# The dotted wire name, in any casing an emitter could produce, used as code.
_DOTTED_AS_CODE = re.compile(r"\b[Ff][Ss]\.[Dd]elete")
_DOUBLE_QUOTED = re.compile(r'"(?:\\.|[^"\\])*"')
_SINGLE_QUOTED = re.compile(r"'(?:\\.|[^'\\])*'")
_LINE_COMMENT = {
    "python": re.compile(r"#.*$"),
    "cpp": re.compile(r"//.*$"),
    "go": re.compile(r"//.*$"),
    "java": re.compile(r"//.*$"),
    "rust": re.compile(r"//.*$"),
    "typescript": re.compile(r"//.*$"),
    "zig": re.compile(r"//.*$"),
}
# Single quotes delimit strings only here (Rust lifetimes, C++/Java/Go/Zig chars).
_SINGLE_QUOTE_STRINGS = {"python", "typescript"}


def _dotted_schema() -> dict:
    document = schema_document()
    command = copy.deepcopy(document["commands"]["list-workspaces"])
    command["request"] = {
        "kind": "object",
        "fields": {
            "paths": {
                "type": {
                    "kind": "array",
                    "items": {"kind": "scalar", "name": "string"},
                },
                "presence": "required",
                "nullable": False,
            }
        },
        "additional_properties": False,
    }
    command["result"] = {
        "kind": "object",
        "fields": {
            "deleted": {
                "type": {"kind": "scalar", "name": "uint32"},
                "presence": "required",
                "nullable": False,
            }
        },
        "additional_properties": False,
    }
    document["commands"][DOTTED] = command
    return document


def _code_lines(language: str, text: str):
    in_block_comment = False
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
            continue
        if stripped.startswith("/*") and "*/" not in stripped:
            in_block_comment = True
            continue
        code = _DOUBLE_QUOTED.sub('""', line)
        if language in _SINGLE_QUOTE_STRINGS:
            code = _SINGLE_QUOTED.sub("''", code)
        code = re.sub(r"/\*.*?\*/", "", code)
        code = _LINE_COMMENT[language].sub("", code)
        yield number, code


class DottedCommandNameTests(unittest.TestCase):
    def test_every_language_turns_a_dotted_command_into_an_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            ir = load_ir(write_schema(Path(raw_directory), _dotted_schema()))
            for language in available_languages():
                with self.subTest(language=language):
                    files = render_files(load_emitter(language), ir)
                    offenders = [
                        f"{path}:{number}: {code.strip()}"
                        for path, content in files.items()
                        for number, code in _code_lines(
                            language, content.decode("utf-8")
                        )
                        if _DOTTED_AS_CODE.search(code)
                    ]
                    self.assertEqual(offenders, [])

    def test_python_output_for_a_dotted_command_parses(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            ir = load_ir(write_schema(Path(raw_directory), _dotted_schema()))
            files = render_files(load_emitter("python"), ir)
        sources = {
            str(path): content.decode("utf-8")
            for path, content in files.items()
            if str(path).endswith(".py")
        }
        for path, source in sources.items():
            with self.subTest(path=path):
                ast.parse(source, filename=path)
        client = ast.parse(sources["client.py"])
        mixin = next(
            node
            for node in client.body
            if isinstance(node, ast.ClassDef) and node.name == "GeneratedClientMixin"
        )
        methods = {
            node.name for node in mixin.body if isinstance(node, ast.FunctionDef)
        }
        self.assertIn("fs_delete", methods)
        models = ast.parse(sources["models.py"])
        classes = {
            node.name for node in models.body if isinstance(node, ast.ClassDef)
        }
        self.assertIn("FsDeleteRequest", classes)
        self.assertIn("FsDeleteResult", classes)

    def test_python_output_for_the_live_schema_parses(self) -> None:
        files = render_files(load_emitter("python"), load_ir(LIVE_SCHEMA))
        for path, content in files.items():
            if str(path).endswith(".py"):
                with self.subTest(path=str(path)):
                    ast.parse(content.decode("utf-8"), filename=str(path))


if __name__ == "__main__":
    unittest.main()
