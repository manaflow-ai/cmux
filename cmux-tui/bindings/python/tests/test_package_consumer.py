from __future__ import annotations

import ast
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.9 and 3.10
    tomllib = None


PROJECT = Path(__file__).resolve().parents[1]


def _project_version() -> str:
    contents = (PROJECT / "pyproject.toml").read_text(encoding="utf-8")
    if tomllib is not None:
        try:
            return tomllib.loads(contents)["project"]["version"]
        except KeyError as error:
            raise RuntimeError("pyproject.toml has no project version") from error

    in_project = False
    for source_line in contents.splitlines():
        line = source_line.strip()
        if line.startswith("[") and line.endswith("]"):
            in_project = line == "[project]"
        elif in_project and line.startswith("version"):
            key, separator, value = line.partition("=")
            if separator and key.strip() == "version":
                try:
                    parsed = ast.literal_eval(value.strip())
                except (SyntaxError, ValueError) as error:
                    raise RuntimeError(
                        "pyproject.toml project version is not a static string"
                    ) from error
                if isinstance(parsed, str):
                    return parsed
                raise RuntimeError(
                    "pyproject.toml project version is not a static string"
                )
    raise RuntimeError("pyproject.toml has no project version")


PROJECT_VERSION = _project_version()


class ProjectVersionTests(unittest.TestCase):
    def test_python_39_fallback_parses_toml_strings_and_comments(self) -> None:
        for version_line in (
            "version = '1.2.3'",
            'version = "1.2.3" # release version',
        ):
            with (
                self.subTest(version_line=version_line),
                tempfile.TemporaryDirectory(prefix="cmux-python-manifest-") as root,
            ):
                project = Path(root)
                (project / "pyproject.toml").write_text(
                    f"[project]\n{version_line}\n",
                    encoding="utf-8",
                )
                with (
                    mock.patch.object(sys.modules[__name__], "PROJECT", project),
                    mock.patch.object(sys.modules[__name__], "tomllib", None),
                ):
                    self.assertEqual(_project_version(), "1.2.3")


class PackagedConsumerTests(unittest.TestCase):
    def test_distributions_install_resource_root_and_raw_legacy_namespace(self) -> None:
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
                    check=False,
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
            distribution_root = os.environ.get("CMUX_PYTHON_DIST_DIR")
            if distribution_root:
                distribution_directory = Path(distribution_root).resolve()
                wheels = sorted(distribution_directory.glob("*.whl"))
                sdists = sorted(distribution_directory.glob("*.tar.gz"))
                self.assertEqual(len(wheels), 1)
                self.assertEqual(len(sdists), 1)
                distributions = (*wheels, *sdists)
            else:
                wheels = scratch / "wheels"
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
                distributions = (next(wheels.glob("cmux_sdk-*.whl")),)

            for index, distribution in enumerate(distributions):
                with self.subTest(distribution=distribution.name):
                    installed = scratch / f"installed-{index}"
                    install_command = [
                        builder,
                        "-m",
                        "pip",
                        "install",
                        "--no-deps",
                    ]
                    if distribution.name.endswith(".tar.gz"):
                        install_command.append("--no-build-isolation")
                    install_command.extend(
                        ["--target", str(installed), str(distribution)]
                    )
                    subprocess.run(
                        install_command,
                        check=True,
                        capture_output=True,
                        text=True,
                    )
                    self.assertTrue((installed / "cmux" / "py.typed").is_file())
                    environment = dict(os.environ)
                    environment["PYTHONPATH"] = str(installed)
                    environment["CMUX_EXPECTED_SDK_VERSION"] = PROJECT_VERSION
                    subprocess.run(
                        [
                            builder,
                            "-c",
                            (
                                "import cmux, cmux.raw, cmux.raw._generated, os;"
                                "from importlib.metadata import version;"
                                "assert version('cmux-sdk') == "
                                "os.environ['CMUX_EXPECTED_SDK_VERSION'];"
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
