# Agent PR review gate

Opted-in agent-authored PRs carry `<!-- agent-pr-review-required -->` in the PR body. The `agent-pr-review-complete` workflow then evaluates current GitHub review threads.

The gate counts only non-outdated inline threads whose first comment comes from the configured actionable review bots (`coderabbitai` and `greptile-apps` by default). Informational summaries, walkthroughs, and rate-limit notices are excluded. A thread is complete only when the PR author has replied after the latest bot comment; resolving the thread without an answer does not satisfy the gate.

The workflow runs in the read-only `pull_request` context with no secrets. It checks out the merge ref only to run this checker; the checker does not execute project code and reads the PR as data. Bot review coverage can be enabled for a repository once its providers expose reliable current-head review records by setting `REQUIRE_BOT_REVIEW_COVERAGE=1` and configuring `REVIEW_BOTS`.
