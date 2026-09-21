# Agent PR review gate

An agent-authored PR opts in by carrying `<!-- agent-pr-review-required -->` in
its body. The `agent-pr-review-complete` workflow then reads GitHub's review
data for the exact PR head. It is opt-in; it does not change branch protection
or add a requirement to ordinary human-authored PRs.

The default review-bot set is `coderabbitai,greptile-apps`; repositories can
replace it with the `AGENT_REVIEW_BOTS` variable. Replies are accepted only
from the configured `AGENT_REVIEW_REPLY_ACTORS` comma-separated list. When that
variable is absent, the workflow explicitly configures the PR author's login.
The checker never treats an arbitrary PR comment as an agent reply.

The read ledger records every configured-bot thread it can capture. A current,
actionable inline finding is active when it is not outdated. Outdated threads
stay in the ledger as `outdated`; resolved threads stay visible with their
resolution state. Summary, walkthrough, and provider rate-limit/unavailable
messages are classified as informational and are excluded from active finding
obligations. A finding with a reply is `answered_unverified`, or
`resolved_unverified` when GitHub also reports resolution. Those dispositions
record evidence of a reply and resolution; a reply alone is not evidence that
the finding was fixed.

The gate fails active findings without a reply from a configured actor. It also
fails if the read capture is incomplete. The GraphQL collector paginates the
review, thread, and per-thread comment connections; a collector error is a
failure rather than a pass. It does not write replies, resolve threads, or
merge PRs.

Current-head provider coverage is part of the default opted-in contract. The
configured providers publish structured review records bound to the reviewed
commit. The workflow defaults `REQUIRE_BOT_REVIEW_COVERAGE` to `1` and
`AGENT_REVIEW_COVERAGE_BOTS` to `greptile-apps`, so Greptile must review the
exact PR head while CodeRabbit findings remain reply obligations whenever
CodeRabbit runs. Repositories can set `AGENT_REVIEW_COVERAGE_BOTS` to a
comma-separated subset of `AGENT_REVIEW_BOTS` (for example,
`coderabbitai,greptile-apps`) to require more providers. Set
`REQUIRE_BOT_REVIEW_COVERAGE=0` only as an explicit degraded mode during a
provider outage; thread-reply obligations still apply, while the gate stops
claiming complete provider coverage. An unavailable required provider never
counts as a review while coverage is enabled.

For an audit-friendly read, run the trusted base-branch checker with
`--json`; it emits `cmux.agent-pr-review/v1` with the PR/head, configured bots
and actors, coverage states, capture completeness, and obligation dispositions.
