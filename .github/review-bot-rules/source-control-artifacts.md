# Source Control Artifacts

Apply this rule to every changed file path.

## Fail

- Local tool output, generated logs, screenshots, recordings, temp folders, dependency checkouts, caches, build output, DerivedData, package-manager downloads, or copied artifacts are added to source control without a deliberate product or documentation reason.
- Hidden scratch directories such as `.iter-logs/`, `.ci-source-packages/`, `.claude/worktrees/`, `.vercel/`, `.next/`, `.swiftpm/`, `.zig-cache/`, `DerivedData/`, `tmp/`, `tmp-*/`, or `artifacts/` appear in the diff.
- A PR adds a new broad artifact directory instead of adding the artifact pattern to `.gitignore` or moving durable evidence to the expected documentation or test fixture location.

## Pass

- Hand-written source, tests, scripts, docs, config, review rules, localization catalogs, fixtures, or small checked-in assets that are intentionally part of the product.
- Generated files that are explicitly required by the build, release, docs, or test system and are already part of the repo's source-of-truth model.
- Existing accidental artifacts that the PR removes or ignores without adding more.

## Report

When this rule fails, name the exact path, explain why it looks like a local/generated artifact, and suggest deleting it from the diff or adding a narrow `.gitignore` entry.
