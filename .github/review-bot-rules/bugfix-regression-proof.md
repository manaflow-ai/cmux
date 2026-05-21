# Bugfix Regression Proof

Apply this rule to PRs that fix a bug, regression, flaky behavior, crash, data loss, broken user flow, or previously incorrect product/runtime behavior.

## Fail

- A bugfix PR changes production app, runtime, CLI, web, script, build, or release behavior without adding or updating a behavior-level regression test for the exact broken path.
- The regression test lands in the same commit as the fix, or only after the fix, so the PR history does not show a red test-only commit followed by a green fix commit.
- The PR claims an existing test covered the bug but does not identify the pre-fix failing test/check and the final passing test/check.
- The test only checks source shape, project metadata, string presence, or implementation snippets instead of runtime behavior, built artifacts, or user-visible outcomes.

## Pass

- PRs that do not claim or implement a bugfix, including pure features, docs-only changes, metadata-only changes, refactors with no claimed broken behavior, and review-bot rule changes.
- A bugfix PR where the first relevant commit adds or adjusts only the failing behavior-level regression test, CI or a reviewer-run check goes red on that commit, and a later commit fixes the bug with the same check going green.
- A bugfix PR where an already-checked-in test demonstrably failed before the fix and the PR identifies the failing pre-fix check plus the final green check.
- Valid regression tests exercise runtime behavior, built artifacts, or user-visible outcomes instead of source shape.

## Report

When this rule fails, name the bugfix signal from the PR title, body, issue, or diff, identify the missing red-first/green-after evidence, and ask for the smallest behavior-level regression test commit that fails before the fix and passes after it.
