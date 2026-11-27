# Proof records

A proof record says what a pre-PR verify loop ran on a pull request's exact head and what came of it. The loop
posts it on the PR, and a gate reads it. Every flow suite shares the format: iOS (`cmux ios verify`, suite
`ios-flows`) and the Mac, web and GUI suites (`mac-flows`, `web-flows`, `gui-flows`) that reuse the FlowSuite
manifest shape (cmux-next-ios/FlowSuite/README.md).

- `schema.json` (here) is the JSON Schema, version 1.
- `scripts/ci/proof_record.py` is the one reader and writer: `render`, `parse`, `find`, `gate`, and the CLI
  (`gate --suite S` for a workflow, `validate FILE`).
- `scripts/ci/ios_verify.py` is the iOS loop that writes one.
- `tests/test_ci_proof_record.py` holds the tests.

## On the PR

The record is one comment. Its first line is `<!-- cmux-proof-record SUITE HEAD_SHA -->`; then comes a short
summary table, then the record in a ```json fence inside `<details>`. A gate:

1. reads the PR's issue comments;
2. keeps those by a collaborator (author_association OWNER, MEMBER or COLLABORATOR) or by a GitHub App the
   repository installed (`quota-goblin-*[bot]`, the pool app a fleet agent's brokered `gh` posts as);
3. takes the newest record of its suite whose `head_sha` is the PR's current head.

A new push means the old record no longer counts, so the loop runs again.

## Fields

| field | meaning |
|---|---|
| `head_sha`, `base_sha`, `merged_base` | the commit the runs built, its merge base, and whether the loop merged a moved base in first |
| `selection` | the selector's output: flows and the tests behind them |
| `runs[]` | one per step: `name`, `result` (pass, fail, error, skipped), `worker`, `step` (the cmux-ci step id), `seconds` |
| `captures[]` | each screenshot's sha256 and its verdict against `baseline`: same, changed, new, missing or unbaselined |
| `visual` | `{screens, baselined, changed, video, diffed}`: what the land-judge visual tier checks. A visual change lands only with screens diffed against the last green build on a real simulator |
| `verdict` | pass only if no run failed and at least one ran. A changed capture is evidence, not a failure |
| `timing` | `pushed_at` (the head commit's time), `proof_at`, `push_to_proof_s` |

## Using it from another suite

Write the record through `proof_record.render(record, summary_md)` and post it with `gh pr comment`. Gate on it
with `python3 -I scripts/ci/proof_record.py gate --suite SUITE`, with env REPO, PR, SHA and GH_TOKEN. That prints
`STATE<TAB>DESCRIPTION`. A record that can't be read prints `error`, never a pass. Adding a suite name means
adding it to `SUITES` and to the schema's enum.
