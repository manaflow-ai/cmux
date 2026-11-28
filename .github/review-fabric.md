# Review fabric receipts

The review fabric owns review state independently of any one provider.

A receipt is bound to one exact pull-request head and records independent review runs plus the findings they published. `.github/scripts/review_fabric.py` evaluates those receipts against `.github/review-fabric-policy.json`.

## Identity

Reviewer independence is keyed by `session_id`, not GitHub login, provider, or model name. One session invoking multiple models still contributes one quorum vote.

Every run records:

- worker/session provenance;
- provider, harness, model, and capability class;
- role;
- exact head SHA;
- rules version;
- status and disposition;
- optional evidence class.

Old-head runs remain auditable but never count toward a current-head quorum.

## Findings

Published actionable findings must have an accepted disposition and a reply after the latest reviewer message. A `declined_with_rationale` finding must include a rationale.

The schema can also retain truthful nonterminal/audit states such as `answered_unverified`, `resolved_unverified`, `resolved_unanswered`, `outdated`, and `unavailable`. Those states remain visible without pretending that a reply or GitHub thread resolution proved the finding was fixed.

The v1 evidence classes follow the Fieldwork distinction:

- `source-read`
- `model-executed`
- `target-test-prepared`
- `target-executed`
- `integration-executed`
- `full-gate`

Synthesis must not silently upgrade one evidence class into another. A finding may use severity `unknown` when a provider does not expose enough structured evidence to classify it without guessing.

## Default policy

The repository policy currently requires:

- two independent completed `reviewer` sessions;
- at least one `frontier` capability-class session;
- no completed `hold`, `execute`, or `reject` run;
- all published actionable findings disposed and answered;
- complete capture.

The policy intentionally names no providers or models. Greptile, CodeRabbit, Claude Code, Codex, local GPU agents, or future reviewers can all produce the same receipt shape.

## CLI

Evaluate a receipt from a file:

```sh
python3 .github/scripts/review_fabric.py \
  --input /path/to/receipt.json \
  --json
```

Or pipe the receipt on stdin:

```sh
cat receipt.json | python3 .github/scripts/review_fabric.py
```

Exit status is zero only when the policy passes.

## Next integration

This is the provider-neutral contract layer. Listener/dispatcher work should create these receipts from exact-head review runs. The existing agent PR obligation ledger can then consume the evaluation instead of treating any named review provider as the source of truth.
