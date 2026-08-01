from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "verify_pypi_provenance.py"
SPEC = importlib.util.spec_from_file_location("verify_pypi_provenance", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
provenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provenance)


class VerifyPyPIProvenanceTests(unittest.TestCase):
    package = "cmux-sdk"
    version = "0.0.0a0"
    repository = "https://github.com/manaflow-ai/cmux"
    filenames = (
        "cmux_sdk-0.0.0a0-py3-none-any.whl",
        "cmux_sdk-0.0.0a0.tar.gz",
    )

    def response(self, filenames: tuple[str, ...]) -> io.BytesIO:
        return io.BytesIO(
            json.dumps(
                {
                    "urls": [
                        {
                            "filename": filename,
                            "url": "https://files.pythonhosted.org/packages/"
                            f"bootstrap/{filename}",
                        }
                        for filename in filenames
                    ]
                }
            ).encode()
        )

    def test_verifies_every_exact_file_against_the_repository(self) -> None:
        with mock.patch.object(
            provenance, "urlopen", return_value=self.response(self.filenames)
        ), mock.patch.object(
            provenance.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0),
        ) as run:
            provenance.verify(
                self.package,
                self.version,
                self.filenames,
                self.repository,
            )

        self.assertEqual(run.call_count, 2)
        for call, filename in zip(run.call_args_list, sorted(self.filenames)):
            command = call.args[0]
            self.assertEqual(command[:5], [
                "pypi-attestations",
                "verify",
                "pypi",
                "--repository",
                self.repository,
            ])
            self.assertTrue(command[-1].endswith(filename))
            self.assertEqual(call.kwargs["timeout"], 60)

    def test_rejects_missing_or_unexpected_files_before_verification(self) -> None:
        with mock.patch.object(
            provenance, "urlopen", return_value=self.response(self.filenames[:1])
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "differ"):
            provenance.verify(
                self.package,
                self.version,
                self.filenames,
                self.repository,
            )
        run.assert_not_called()

    def test_rejects_a_failed_attestation_without_exposing_its_output(self) -> None:
        with mock.patch.object(
            provenance, "urlopen", return_value=self.response(self.filenames)
        ), mock.patch.object(
            provenance.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 1),
        ), self.assertRaisesRegex(provenance.ProvenanceError, "does not match"):
            provenance.verify(
                self.package,
                self.version,
                self.filenames,
                self.repository,
            )


if __name__ == "__main__":
    unittest.main()
