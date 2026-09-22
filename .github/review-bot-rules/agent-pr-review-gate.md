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
review, thread, PR summary-comment, and per-thread comment connections; a collector error is a
failure rather than a pass. It does not write replies, resolve threads, or
merge PRs.

Current-head provider coverage is part of the opted-in agent PR contract.
The workflow defaults `AGENT_REQUIRED_REVIEW_COVERAGE_BOTS` to
`greptile-apps`, so the gate stays red until Greptile records a review of the
exact PR head. Greptile reuses one summary comment across re-reviews, so the
checker accepts its `Last reviewed commit` SHA as current-head evidence and
falls back to a current-head PullRequestReview when present. It never treats an
older Greptile review object as coverage for a newer head.

Greptile is configured with `triggerOnUpdates: true` and `statusCheck: true`.
On each `pull_request_target` head event, the trusted workflow first checks for
a current Greptile review, an in-progress Greptile check, or its own per-head
request marker. When none exists it posts exactly one `@greptile review`
request for that head. Only `github-actions[bot]` markers suppress a repeat, so
a PR author cannot forge the request state.

The workflow listens to both `pull_request_review` and PR `issue_comment`
updates, so either a new review object or an updated Greptile summary reevaluates
the gate automatically.

Repositories can replace the required coverage subset with
`AGENT_REQUIRED_REVIEW_COVERAGE_BOTS`. The older
`REQUIRE_BOT_REVIEW_COVERAGE=1` switch remains as a compatibility mode that
requires every configured `AGENT_REVIEW_BOTS` provider when no explicit
coverage subset is set. An unavailable provider never counts as a current-head
review.

For an audit-friendly read, run the trusted base-branch checker with
`--json`; it emits `cmux.agent-pr-review/v1` with the PR/head, configured bots
and actors, coverage states, capture completeness, and obligation dispositions.
