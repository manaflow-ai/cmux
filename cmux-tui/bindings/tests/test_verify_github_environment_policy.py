from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify_github_environment_policy.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_github_environment_policy",
    SCRIPT,
)
assert SPEC is not None
assert SPEC.loader is not None
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class VerifyGithubEnvironmentPolicyTests(unittest.TestCase):
    environment_name = "sdk-release-credentials"
    dispatcher = "lawrencecchen"

    def environment(
        self,
        *,
        reviewers: object = None,
        prevent_self_review: object = True,
        can_admins_bypass: object = False,
        deployment_branch_policy: object = None,
    ) -> dict[str, object]:
        if reviewers is None:
            reviewers = [
                {
                    "type": "User",
                    "reviewer": {"login": "austinywang"},
                }
            ]
        if deployment_branch_policy is None:
            deployment_branch_policy = {
                "protected_branches": True,
                "custom_branch_policies": False,
            }
        return {
            "name": self.environment_name,
            "can_admins_bypass": can_admins_bypass,
            "deployment_branch_policy": deployment_branch_policy,
            "protection_rules": [
                {
                    "type": "required_reviewers",
                    "prevent_self_review": prevent_self_review,
                    "reviewers": reviewers,
                },
                {"type": "branch_policy"},
            ],
        }

    def assert_rejected(self, payload: dict[str, object]) -> None:
        with self.assertRaises(policy.EnvironmentPolicyError):
            policy.validate_environment_policy(
                payload,
                self.environment_name,
                self.dispatcher,
            )

    def test_accepts_a_protected_environment_with_another_reviewer(self) -> None:
        policy.validate_environment_policy(
            self.environment(),
            self.environment_name,
            self.dispatcher,
        )

    def test_rejects_missing_required_reviewer_rule(self) -> None:
        payload = self.environment()
        payload["protection_rules"] = [{"type": "branch_policy"}]
        self.assert_rejected(payload)

    def test_rejects_self_review_only(self) -> None:
        self.assert_rejected(
            self.environment(
                reviewers=[
                    {
                        "type": "User",
                        "reviewer": {"login": self.dispatcher},
                    }
                ]
            )
        )

    def test_rejects_self_review_setting_disabled(self) -> None:
        self.assert_rejected(self.environment(prevent_self_review=False))

    def test_rejects_administrator_bypass(self) -> None:
        self.assert_rejected(self.environment(can_admins_bypass=True))

    def test_rejects_unprotected_or_custom_branch_policy(self) -> None:
        self.assert_rejected(
            self.environment(
                deployment_branch_policy={
                    "protected_branches": False,
                    "custom_branch_policies": True,
                }
            )
        )

    def test_accepts_a_team_reviewer_with_self_review_disabled(self) -> None:
        policy.validate_environment_policy(
            self.environment(
                reviewers=[
                    {
                        "type": "Team",
                        "reviewer": {"slug": "sdk-release-reviewers"},
                    }
                ]
            ),
            self.environment_name,
            self.dispatcher,
        )


if __name__ == "__main__":
    unittest.main()
