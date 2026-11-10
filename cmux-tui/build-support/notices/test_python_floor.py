#!/usr/bin/env python3
"""Under a python3 older than 3.11 (macOS's /usr/bin/python3 is 3.9.6) the
notices tools end with one line that names the needed version and the
interpreter, and the generator says it before any download.

Nightly run 42775849251: an owned Mac had only that python3, and "Generate the
third-party notices" ended, after its downloads, in a traceback from
`import tomllib`.

No python older than 3.11 need be installed here: the tool runs in an
interpreter that reports 3.9.6 and cannot import tomllib, as a real 3.9 does.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
GENERATOR = ROOT / "scripts/cmux-next/generate-third-party-notices.sh"
# Every tool of this folder that reads TOML (rust_notices.py through cargo_inputs.py).
TOML_TOOLS = ("fetch_crates.py", "rust_notices.py", "review_list.py", "fetch_reviewed_text.py")

AS_PYTHON_3_9 = """
import collections, runpy, sys
script = sys.argv[1]
sys.argv = sys.argv[1:]
sys.path[0] = __import__("os").path.dirname(script)  # what `python3 script` does
sys.modules["tomllib"] = None  # import tomllib raises ImportError, as on 3.9
sys.version_info = collections.namedtuple("version_info", "major minor micro releaselevel serial")(3, 9, 6, "final", 0)
runpy.run_path(script, run_name="__main__")
"""


def run_as_python_3_9(tool: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-c", AS_PYTHON_3_9, str(HERE / tool), "--help"],
                          capture_output=True, text=True)


class OldPython(unittest.TestCase):
    def test_each_toml_tool_ends_with_one_line_that_names_the_floor_and_the_interpreter(self):
        for tool in TOML_TOOLS:
            with self.subTest(tool=tool):
                result = run_as_python_3_9(tool)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)
                lines = result.stderr.splitlines()
                self.assertEqual(len(lines), 1, result.stderr)
                self.assertIn("Python 3.11", lines[0])
                self.assertIn("3.9.6", lines[0])
                self.assertIn(sys.executable, lines[0])

    def test_this_python_runs_the_tools(self):
        for tool in TOML_TOOLS:
            with self.subTest(tool=tool):
                result = subprocess.run([sys.executable, str(HERE / tool), "--help"], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")


class Generator(unittest.TestCase):
    def test_the_generator_checks_python_before_any_other_work(self):
        """A python3 that fails every call: the generator must stop at its first
        call, and that call is the floor check (no pin read, no git, no download)."""
        with tempfile.TemporaryDirectory() as temp:
            calls = Path(temp) / "calls"
            fake = Path(temp) / "bin/python3"
            fake.parent.mkdir()
            fake.write_text(f'#!/bin/sh\necho "$1" >> "{calls}"\necho "floor says no" >&2\nexit 1\n')
            fake.chmod(0o755)
            env = {**os.environ, "PATH": f"{fake.parent}{os.pathsep}{os.environ['PATH']}",
                   "CMUX_NOTICES_CACHE": str(Path(temp) / "cache")}
            result = subprocess.run([str(GENERATOR), "--tui-source", "tree"], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls.read_text().splitlines(), [str(HERE / "python_floor.py")])
            self.assertEqual(result.stderr, "floor says no\n")
            self.assertFalse((Path(temp) / "cache").exists())


if __name__ == "__main__":
    unittest.main()
