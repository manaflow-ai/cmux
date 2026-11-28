from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "verify_npm_provenance.py"
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("verify_npm_provenance", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
provenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provenance)


class VerifyNpmProvenanceTests(unittest.TestCase):
    commit = "a" * 40
    package = "cmux-sdk"
    version = "0.0.0-bootstrap.0"
    owner = "lawrencechen"
    workflow = ".github/workflows/sdk-bootstrap-npm.yml"
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

    def metadata(
        self,
        *,
        dist_tag: str = "bootstrap",
        publisher: str = "owner",
    ) -> dict[str, object]:
        npm_user: dict[str, object]
        if publisher == "github-actions":
            npm_user = {
                "name": "GitHub Actions",
                "email": "npm-oidc-no-reply@github.com",
                "trustedPublisher": {
                    "id": "github",
                    "oidcConfigId": "oidc:expected-configuration",
                },
            }
        else:
            npm_user = {"name": self.owner}
        return {
            "name": self.package,
            "dist-tags": {dist_tag: self.version},
            "maintainers": [{"name": self.owner}],
            "versions": {
                self.version: {
                    "name": self.package,
                    "version": self.version,
                    "repository": {
                        "type": "git",
                        "url": self.repository_url,
                        "directory": self.repository_directory,
                    },
                    "_npmUser": npm_user,
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

    def attestation(
        self,
        *,
        commit: str | None = None,
        event_name: str = "repository_dispatch",
        workflow: str | None = None,
    ) -> dict[str, object]:
        statement = {
            "_type": "https://in-toto.io/Statement/v1",
            "subject": [{
                "name": f"pkg:npm/{self.package}@{self.version}",
                "digest": {
                    "sha512": hashlib.sha512(
                        self.artifact.read_bytes()
                    ).hexdigest()
                },
            }],
            "predicateType": provenance.PREDICATE_TYPE,
            "predicate": {
                "buildDefinition": {
                    "buildType": provenance.GITHUB_WORKFLOW_BUILD_TYPE,
                    "externalParameters": {
                        "workflow": {
                            "ref": "refs/heads/main",
                            "repository": "https://github.com/manaflow-ai/cmux",
                            "path": workflow or self.workflow,
                        }
                    },
                    "internalParameters": {
                        "github": {
                            "event_name": event_name,
                            "repository_id": "1144115288",
                            "repository_owner_id": "171392238",
                        }
                    },
                    "resolvedDependencies": [{
                        "uri": (
                            "git+https://github.com/manaflow-ai/cmux"
                            "@refs/heads/main"
                        ),
                        "digest": {"gitCommit": commit or self.commit},
                    }],
                },
                "runDetails": {
                    "builder": {"id": provenance.GITHUB_HOSTED_BUILDER},
                    "metadata": {
                        "invocationId": (
                            "https://github.com/manaflow-ai/cmux/actions/runs/"
                            "123/attempts/1"
                        )
                    },
                },
            },
        }
        payload = base64.b64encode(json.dumps(statement).encode()).decode("ascii")
        return {
            "attestations": [{
                "predicateType": provenance.PREDICATE_TYPE,
                "bundle": {"dsseEnvelope": {"payload": payload}},
            }]
        }

    def response(self, payload: dict[str, object]) -> io.BytesIO:
        return io.BytesIO(json.dumps(payload).encode())

    def registry_response(
        self,
        *,
        metadata: dict[str, object] | None = None,
        attestation: dict[str, object] | None = None,
    ):
        project = metadata if metadata is not None else self.metadata()
        provenance_payload = (
            attestation if attestation is not None else self.attestation()
        )

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            if "/-/npm/v1/attestations/" in url:
                return self.response(provenance_payload)
            return self.response(project)

        return response

    def verification_options(
        self,
        *,
        dist_tag: str = "bootstrap",
        publisher: str = "owner",
    ) -> dict[str, str]:
        options = {
            "owner": self.owner,
            "workflow": self.workflow,
            "workflow_ref": "refs/heads/main",
            "dist_tag": dist_tag,
            "publisher": publisher,
        }
        if publisher == "github-actions":
            options["expected_commit"] = self.commit
        return options

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
            side_effect=self.registry_response(),
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
                **self.verification_options(),
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

    def test_accepts_npm_latest_for_the_sole_bootstrap_release(self) -> None:
        metadata = self.metadata()
        metadata["dist-tags"]["latest"] = self.version
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
            side_effect=self.registry_response(metadata=metadata),
        ), mock.patch.object(
            provenance.subprocess,
            "run",
            side_effect=completed,
        ):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                required_dist_tags=("latest",),
                **self.verification_options(),
            )

    def test_accepts_a_stable_latest_tag_after_bootstrap(self) -> None:
        metadata = self.metadata()
        metadata["dist-tags"]["latest"] = "1.0.0+build-1"
        stable_release = dict(metadata["versions"][self.version])
        stable_release["version"] = "1.0.0+build-1"
        metadata["versions"]["1.0.0+build-1"] = stable_release
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
            side_effect=self.registry_response(metadata=metadata),
        ), mock.patch.object(
            provenance.subprocess,
            "run",
            side_effect=completed,
        ):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                required_dist_tags=("latest",),
                **self.verification_options(),
            )

    def test_rejects_bootstrap_latest_after_a_stable_release_exists(self) -> None:
        metadata = self.metadata()
        metadata["dist-tags"]["latest"] = self.version
        stable_release = dict(metadata["versions"][self.version])
        stable_release["version"] = "1.0.0"
        metadata["versions"]["1.0.0"] = stable_release
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(metadata=metadata),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "prerelease"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                required_dist_tags=("latest",),
                **self.verification_options(),
            )
        run.assert_not_called()

    def test_rejects_a_missing_required_bootstrap_dist_tag(self) -> None:
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "dist-tag"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                required_dist_tags=("latest",),
                **self.verification_options(),
            )
        run.assert_not_called()

    def test_accepts_matching_sha512_in_multi_entry_sri(self) -> None:
        metadata = self.metadata()
        metadata["versions"][self.version]["dist"]["integrity"] = (
            f"sha256-ignored {self.integrity()}"
        )
        completed = (
            subprocess.CompletedProcess([], 0, stdout="", stderr=""),
            subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps({"invalid": [], "missing": []}),
                stderr="",
            ),
        )

        for artifact in (self.artifact, None):
            with self.subTest(artifact=artifact), mock.patch.object(
                provenance,
                "urlopen",
                side_effect=self.registry_response(metadata=metadata),
            ), mock.patch.object(
                provenance.subprocess,
                "run",
                side_effect=completed,
            ):
                provenance.verify(
                    self.package,
                    self.version,
                    self.repository_url,
                    self.repository_directory,
                    artifact,
                    **self.verification_options(),
                )

    def test_verifies_a_stable_github_actions_publisher(self) -> None:
        self.version = "1.0.0"
        self.workflow = ".github/workflows/sdk-release-cut.yml"
        completed = (
            subprocess.CompletedProcess([], 0, stdout="", stderr=""),
            subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps({"invalid": [], "missing": []}),
                stderr="",
            ),
        )
        metadata = self.metadata(
            dist_tag="latest",
            publisher="github-actions",
        )
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(metadata=metadata),
        ), mock.patch.object(
            provenance.subprocess,
            "run",
            side_effect=completed,
        ):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                **self.verification_options(
                    dist_tag="latest",
                    publisher="github-actions",
                ),
            )

    def test_rejects_the_wrong_repository_before_running_npm(self) -> None:
        metadata = self.metadata()
        metadata["versions"][self.version]["repository"]["url"] = (
            "git+https://github.com/attacker/cmux.git"
        )
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(metadata=metadata),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "repository"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                **self.verification_options(),
            )
        run.assert_not_called()

    def test_rejects_a_publisher_that_is_no_longer_a_maintainer(self) -> None:
        metadata = self.metadata()
        metadata["maintainers"] = [{"name": "attacker"}]
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(metadata=metadata),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "maintainer"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                **self.verification_options(),
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
            side_effect=self.registry_response(),
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
                **self.verification_options(),
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
            side_effect=self.registry_response(metadata=metadata),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "bytes"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                **self.verification_options(),
            )
        run.assert_not_called()

    def test_rejects_an_attestation_from_the_wrong_workflow(self) -> None:
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(
                attestation=self.attestation(workflow=".github/workflows/attacker.yml")
            ),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "workflow"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                **self.verification_options(),
            )
        run.assert_not_called()

    def test_rejects_a_branch_dispatch_attestation(self) -> None:
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(
                attestation=self.attestation(event_name="workflow_dispatch")
            ),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "repository"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                **self.verification_options(),
            )
        run.assert_not_called()

    def test_rejects_stable_provenance_from_a_different_commit(self) -> None:
        self.version = "1.0.0"
        self.workflow = ".github/workflows/sdk-release-cut.yml"
        metadata = self.metadata(
            dist_tag="latest",
            publisher="github-actions",
        )
        with mock.patch.object(
            provenance,
            "urlopen",
            side_effect=self.registry_response(
                metadata=metadata,
                attestation=self.attestation(commit="b" * 40),
            ),
        ), mock.patch.object(provenance.subprocess, "run") as run, \
            self.assertRaisesRegex(provenance.ProvenanceError, "source commit"):
            provenance.verify(
                self.package,
                self.version,
                self.repository_url,
                self.repository_directory,
                self.artifact,
                **self.verification_options(
                    dist_tag="latest",
                    publisher="github-actions",
                ),
            )
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
