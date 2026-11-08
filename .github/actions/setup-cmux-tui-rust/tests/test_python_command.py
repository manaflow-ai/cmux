#!/usr/bin/env python3
"""Behavior test for composite-action Python command precedence."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


class PythonCommandTests(unittest.TestCase):
    def test_requested_command_wins_over_ambient_python3(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ambient = root / "python3"
            requested = root / "trusted-python"
            ambient.write_text("#!/bin/sh\nprintf ambient\n")
            requested.write_text("#!/bin/sh\nprintf requested\n")
            ambient.chmod(0o755)
            requested.chmod(0o755)
            script = """
            if [[ -n \"$REQUESTED_PYTHON_COMMAND\" ]]; then
              python_cmd=\"$REQUESTED_PYTHON_COMMAND\"
            elif command -v python3 >/dev/null 2>&1; then
              python_cmd=python3
            elif command -v python >/dev/null 2>&1; then
              python_cmd=python
            else
              exit 1
            fi
            \"$python_cmd\"
            """
            result = subprocess.run(
                ["bash", "-euc", script],
                env={
                    **os.environ,
                    "PATH": f"{root}:/bin:/usr/bin",
                    "REQUESTED_PYTHON_COMMAND": str(requested),
                },
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.stdout, "requested")


if __name__ == "__main__":
    unittest.main()
