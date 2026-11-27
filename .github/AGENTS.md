# .github/ agent instructions

The workflows and the config files that register them. Scripts, tests and the git hooks:
[scripts/AGENTS.md](../scripts/AGENTS.md). Merge rules: [docs/ci/landing.md](../docs/ci/landing.md).

## The workflows that gate a pull request

There are about 270 files in `workflows/`. Most work lands on `feat-cmux-next`; its pull requests run:

- `pr-router.yml` ("pr router"): lists the changed files once. `scripts/ci/pr_router.py` and
  `scripts/ci/pr_router.json` pick which callees run: `pr-pipeline.yml`, `swift-linux-packages.yml`,
  `classic-api-guard.yml`, `cmux-next-size-budget.yml`, `cmux-next-fast-gates.yml`.
- `pr-pipeline.yml`: the `linux` steps of `ci/steps.toml` that the change routes, run by `ci/run`.
- `cmux-next-guards.yml`: the `ci-guards.yml` guard tests a change reaches; a push runs the release-notary
  group at the tip.
- `cmux-next.yml`: the macOS build and Swift test lane, routed by its `path_route` job. Its `# Why:` lines
  point into [docs/ci/cmux-next-workflow-notes.md](../docs/ci/cmux-next-workflow-notes.md).
- `cmux-next-fast-gates.yml`: four push-time checks in fail mode, on the PR merged with its base; a pr-router
  callee (checks `cmux-next fast gates / <job>`), so a head the router starts nothing for runs none of it.
- Required on the branch: `clippy (changed cmux-tui packages)` (`cmux-tui-spec.yml`) and
  `React Doctor (changed React projects)` (`cmux-next-react-doctor.yml`). Both fail only on errors, not lints.
- Advisory, never red: `pr-checks.yml`; description lints: `pr-body-checks.yml`.
- After merge, `cmux-next-post-merge.yml` runs the deferred suites in batches (`post-merge-batch.json`).

Into `main`: `ci.yml` ("CI") calls `ci-guards.yml`, `ci-web.yml` and `ci-macos.yml`, and reports `ci-status`.
`ci-fast-guards.yml` runs the guards' `ci` group on each push to main. `nightly.yml` builds NIGHTLY.

## Adding or changing a workflow

Do these in the same pull request:

1. Every job has `timeout-minutes`, and an `if:` with `always()` also has `!cancelled()`. A job that must run
   on a cancel is listed with its reason in `workflow-job-bounds.json`. The pre-push gate refuses a new miss.
2. A new pull request workflow into feat-cmux-next: give it `workflow_call:`, move its `pull_request` trigger
   into `scripts/ci/pr_router.json`, add a caller job in `pr-router.yml`, then run
   `python3 scripts/ci/pr_router.py check`. A new check is often better as a step in `ci/steps.toml`
   (`tests/test_ci_step_table.py` holds its rules).
3. Each pull request job declares what it reads (`python3 scripts/ci/job_inputs.py check`). One that does not
   is recorded as runs-always by `job_inputs.py fix`, the PR autofix; it is never refused.
4. A `runs-on` variable names its single-host fallback in `single-host-fallbacks.json` (pre-push gate). A
   literal self-hosted label goes in `actionlint.yaml`, or the "Lint every workflow" step fails.
5. A `paths:` block between the `docs-only paths: BEGIN` and `END` comments is generated: edit
   `DOCS_ONLY_PATHS` in `scripts/ci/docs_only_paths.py`, then run it with `--sync`.
6. A scheduled workflow runs main's copy. The gate's "Scheduled workflows match main's" check compares it
   with `origin/main`.
7. A test that holds the workflow's behavior needs a workflow step that runs it and a registry entry
   (scripts/AGENTS.md, "Mechanical reds").

## Lint a workflow

- `python3 scripts/cmux-next/prepush-gate.py` checks that changed workflows parse, and adds actionlint's
  syntax findings when `actionlint` is on PATH.
- CI's full lint is the "Lint every workflow" step in `ci-guards.yml` (group `ci`). It installs the pinned
  manaflow-ai/actionlint build with `scripts/ci/install-actionlint.sh`; the config is `actionlint.yaml`.
- Job bounds with the allowlist: `python3 tests/test_ci_workflow_job_bounds.py`. The bare
  `scripts/ci/workflow_job_bounds.py .github/workflows` ignores the allowlist and also lists allowed jobs.
- Every `ci`-group guard step (workflow tests among them): `python3 scripts/ci/run_ci_guards.py --group ci`.

## Deeper docs

- [docs/ci/landing.md](../docs/ci/landing.md), [docs/ci/risk-tiers.md](../docs/ci/risk-tiers.md)
- [docs/ci-runners.md](../docs/ci-runners.md): runner labels and repo variables
- [skills/cmux-testing/references/pr-ci-coverage.md](../skills/cmux-testing/references/pr-ci-coverage.md)
