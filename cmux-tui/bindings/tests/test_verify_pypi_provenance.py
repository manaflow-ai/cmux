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
    workflow = "sdk-bootstrap-pypi.yml"
    environment = "pypi-bootstrap"
    owners = ("lawrencecchen",)
    filenames = (
        "cmux_sdk-0.0.0a0-py3-none-any.whl",
        "cmux_sdk-0.0.0a0.tar.gz",
    )

    def metadata(self, filenames: tuple[str, ...]) -> dict[str, object]:
        return {
            "ownership": {
                "organization": None,
                "roles": [
                    {"role": "Owner", "user": owner}
                    for owner in self.owners
                ],
            },
            "urls": [
                {
                    "filename": filename,
                    "url": "https://files.pythonhosted.org/packages/"
                    f"bootstrap/{filename}",
                }
                for filename in filenames
            ],
        }

    def provenance_payload(
        self,
        *,
        workflow: str | None = None,
    ) -> dict[str, object]:
        return {
            "version": 1,
            "attestation_bundles": [{
                "publisher": {
                    "claims": None,
                    "environment": self.environment,
                    "kind": "GitHub",
                    "repository": "manaflow-ai/cmux",
                    "workflow": workflow or self.workflow,
                },
                "attestations": [{"version": 1}],
            }],
        }

    def response(self, payload: dict[str, object]) -> io.BytesIO:
        return io.BytesIO(json.dumps(payload).encode())

    def registry_response(
        self,
        filenames: tuple[str, ...],
        *,
        workflow: str | None = None,
    ):
        metadata = self.metadata(filenames)
        provenance_payload = self.provenance_payload(workflow=workflow)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            if "/integrity/" in url:
                return self.response(provenance_payload)
            return self.response(metadata)

        return response

    def test_verifies_every_exact_file_against_the_repository(self) -> None:
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(self.filenames),
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
                self.owners,
                self.workflow,
                self.environment,
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
            provenance,
            "urlopen",
            side_effect=self.registry_response(self.filenames[:1]),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "differ"):
            provenance.verify(
                self.package,
                self.version,
                self.filenames,
                self.repository,
                self.owners,
                self.workflow,
                self.environment,
            )
        run.assert_not_called()

    def test_rejects_a_failed_attestation_without_exposing_its_output(self) -> None:
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(self.filenames),
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
                self.owners,
                self.workflow,
                self.environment,
            )

    def test_rejects_an_unexpected_current_owner(self) -> None:
        self.owners = ("lawrencecchen", "attacker")
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(self.filenames),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "owner"):
            provenance.verify(
                self.package,
                self.version,
                self.filenames,
                self.repository,
                ("lawrencecchen",),
                self.workflow,
                self.environment,
            )
        run.assert_not_called()

    def test_rejects_provenance_from_an_unexpected_workflow(self) -> None:
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(
                self.filenames,
                workflow="attacker.yml",
            ),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "publisher"):
            provenance.verify(
                self.package,
                self.version,
                self.filenames,
                self.repository,
                self.owners,
                self.workflow,
                self.environment,
            )
        run.assert_not_called()

    def test_rejects_malformed_publisher_claims(self) -> None:
        metadata = self.metadata(self.filenames)
        provenance_payload = self.provenance_payload()
        bundles = provenance_payload["attestation_bundles"]
        assert isinstance(bundles, list)
        publisher = bundles[0]["publisher"]
        assert isinstance(publisher, dict)
        publisher["claims"] = []

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            return self.response(
                provenance_payload if "/integrity/" in url else metadata
            )

        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=response,
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "claims"):
            provenance.verify(
                self.package,
                self.version,
                self.filenames,
                self.repository,
                self.owners,
                self.workflow,
                self.environment,
            )
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
