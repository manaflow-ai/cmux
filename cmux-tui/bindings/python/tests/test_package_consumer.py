from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class PackagedConsumerTests(unittest.TestCase):
    def test_wheel_installs_resource_root_and_raw_legacy_namespace(self) -> None:
        builder = next(
            (
                executable
                for executable in (
                    sys.executable,
                    shutil.which("python3.9"),
                    shutil.which("python3.10"),
                    shutil.which("python3.11"),
                    shutil.which("python3.12"),
                )
                if executable is not None
                and subprocess.run(
                    [
                        executable,
                        "-c",
                        "import setuptools.build_meta",
                    ],
                    capture_output=True,
                ).returncode
                == 0
            ),
            None,
        )
        if builder is None:
            self.skipTest("no Python interpreter has the setuptools build backend")
        with tempfile.TemporaryDirectory(prefix="cmux-python-wheel-") as root:
            scratch = Path(root)
            wheels = scratch / "wheels"
            installed = scratch / "installed"
            wheels.mkdir()
            subprocess.run(
                [
                    builder,
                    "-m",
                    "pip",
                    "wheel",
                    "--no-deps",
                    "--no-build-isolation",
                    "--wheel-dir",
                    str(wheels),
                    str(PROJECT),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            wheel = next(wheels.glob("cmux-*.whl"))
            subprocess.run(
                [
                    builder,
                    "-m",
                    "pip",
                    "install",
                    "--no-deps",
                    "--target",
                    str(installed),
                    str(wheel),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(installed)
            subprocess.run(
                [
                    builder,
                    "-c",
                    (
                        "import cmux, cmux.raw, cmux.raw._generated;"
                        "assert hasattr(cmux, 'Client');"
                        "assert hasattr(cmux, 'ConfirmationRequiredDetails');"
                        "assert hasattr(cmux, 'ConfirmationRequiredError');"
                        "assert hasattr(cmux.Session, 'report_agent');"
                        "assert not hasattr(cmux.Agent, 'report');"
                        "report = cmux.AgentReportOptions("
                        "terminal_id=cmux.TerminalId("
                        "'term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'"
                        "), state='working', source='socket');"
                        "assert report.terminal_id == cmux.TerminalId("
                        "'term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'"
                        ");"
                        "assert cmux.CreateScreenOptions("
                        "correlation_key='consumer-key'"
                        ").correlation_key == 'consumer-key';"
                        "assert not hasattr(cmux, 'ProviderScope');"
                        "assert not hasattr(cmux, 'CmuxClient');"
                        "assert hasattr(cmux.raw, 'CmuxClient');"
                        "assert hasattr(cmux.raw, 'COMMANDS');"
                        "\ntry:\n import cmux._generated\n"
                        "except ModuleNotFoundError:\n pass\n"
                        "else:\n raise AssertionError('cmux._generated leaked')"
                    ),
                ],
                cwd=scratch,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )


if __name__ == "__main__":
    unittest.main()
