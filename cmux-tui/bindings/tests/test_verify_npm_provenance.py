from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "verify_npm_provenance.py"
SPEC = importlib.util.spec_from_file_location("verify_npm_provenance", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
provenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provenance)


class VerifyNpmProvenanceTests(unittest.TestCase):
    package = "cmux-sdk"
    version = "0.0.0-bootstrap.0"
    repository_url = "git+https://github.com/manaflow-ai/cmux.git"
    repository_directory = "cmux-tui/bindings/typescript"

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.artifact = Path(self.temporary_directory.name) / "cmux-sdk.tgz"
        self.artifact.write_bytes(b"exact bootstrap artifact")

    def integrity(self) -> str:
        digest = hashlib.sha512(self.artifact.read_bytes()).digest()
        return "sha512-" + base64.b64encode(digest).decode("ascii")

    def metadata(self) -> dict[str, object]:
        return {
            "name": self.package,
            "dist-tags": {"bootstrap": self.version},
            "maintainers": [{"name": "cmux-owner"}],
            "versions": {
                self.version: {
                    "name": self.package,
                    "version": self.version,
                    "repository": {
                        "type": "git",
                        "url": self.repository_url,
                        "directory": self.repository_directory,
                    },
                    "_npmUser": {"name": "cmux-owner"},
                    "dist": {
                        "integrity": self.integrity(),
                        "attestations": {
                            "url": (
                                "https://registry.npmjs.org/-/npm/v1/attestations/"
                                f"{self.package}@{self.version}"
                            ),
                            "provenance": {
                                "predicateType": "https://slsa.dev/provenance/v1"
                            },
                        },
                    },
                }
            },
        }

    def response(self, metadata: dict[str, object]) -> io.BytesIO:
        return io.BytesIO(json.dumps(metadata).encode())

    def test_verifies_exact_repository_provenance_with_pinned_npm(self) -> None:
        completed = (
            subprocess.CompletedProcess([], 0, stdout="", stderr=""),
            subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps({"invalid": [], "missing": []}),
                stderr="",
            ),
        )
        with mock.patch.object(
            provenance,
            "urlopen",
            return_value=self.response(self.metadata()),
        ), mock.patch.object(
            provenance.subprocess,
            "run",
            side_effect=completed,
        ) as run:
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
            )

        self.assertEqual(run.call_count, 2)
        install, audit = (call.args[0] for call in run.call_args_list)
        self.assertIn("--ignore-scripts", install)
        self.assertIn(f"{self.package}@{self.version}", install)
        self.assertEqual(audit[:3], ["npm", "audit", "signatures"])
        environment = run.call_args_list[0].kwargs["env"]
        self.assertEqual(environment["NPM_CONFIG_REGISTRY"], provenance.REGISTRY)
        self.assertNotEqual(
            environment["NPM_CONFIG_GLOBALCONFIG"],
            environment["NPM_CONFIG_USERCONFIG"],
        )
        for name in environment:
            self.assertNotIn("TOKEN", name.upper())

    def test_rejects_the_wrong_repository_before_running_npm(self) -> None:
        metadata = self.metadata()
        metadata["versions"][self.version]["repository"]["url"] = (
            "git+https://github.com/attacker/cmux.git"
        )
        with mock.patch.object(
            provenance,
            "urlopen",
            return_value=self.response(metadata),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "repository"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
            )
        run.assert_not_called()

    def test_rejects_a_publisher_that_is_no_longer_a_maintainer(self) -> None:
        metadata = self.metadata()
        metadata["maintainers"] = [{"name": "attacker"}]
        with mock.patch.object(
            provenance,
            "urlopen",
            return_value=self.response(metadata),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "maintainer"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
            )
        run.assert_not_called()

    def test_rejects_a_failed_signature_audit_without_exposing_output(self) -> None:
        secret = "registry-secret"
        completed = (
            subprocess.CompletedProcess([], 0, stdout="", stderr=""),
            subprocess.CompletedProcess([], 1, stdout=secret, stderr=secret),
        )
        with mock.patch.object(
            provenance,
            "urlopen",
            return_value=self.response(self.metadata()),
        ), mock.patch.object(
            provenance.subprocess,
            "run",
            side_effect=completed,
        ), self.assertRaises(provenance.ProvenanceError) as failure:
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
            )
        self.assertNotIn(secret, str(failure.exception))

    def test_rejects_different_bootstrap_bytes_before_running_npm(self) -> None:
        metadata = self.metadata()
        metadata["versions"][self.version]["dist"]["integrity"] = (
            "sha512-different"
        )
        with mock.patch.object(
            provenance,
            "urlopen",
            return_value=self.response(metadata),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "bytes"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
            )
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
