<!-- Before drafting or revising this description, read ../STYLE.md. Lead with the problem and the resulting behavior, keep it proportional, and delete any section or checklist line that does not apply. -->
<!-- First pull request here? docs/start-here.md covers what reviewers look for and what CI runs for you: https://github.com/manaflow-ai/cmux/blob/main/docs/start-here.md -->

## Summary

<!-- The concrete problem, and what a user or API caller can do after this change. Explain as much of the mechanism as a reviewer needs to assess it; link deeper design or implementation detail. If this closes an issue, say `Fixes #1234` here. -->

## Testing

<!--
Say what ran, what passed, and what that establishes. Keep these apart:
- Tests added vs. tests executed. Name the command or CI lane that ran them; a green job whose tests were skipped is not coverage.
- Compiled vs. ran vs. checked live in a tagged build.
- Anything still unverified, stated once, next to the claim it limits.
Bug fix? Name the focused command that fails on the base and passes on the head, then add
`### Observed / Not run`: what you ran and saw, then what you only read or didn't run.
gh-merge-green warns when a fix PR has no Observed section.
The contributor verification ladder suggests the first useful check for each kind of change:
https://github.com/manaflow-ai/cmux/blob/main/docs/contributor-verification.md
-->

## Changelog

<!--
Keep this section. Write one line for the release notes, or `none` for internal-only changes (CI, tests, docs, refactors, build scripts).
Start with Added:, Changed:, Fixed:, or Removed:, then say in present tense what a user sees rather than how it was built. Leave out the PR link and credit; /release adds both.
Example: Fixed: Closing the last workspace no longer unfolds a collapsed sidebar group above it
Left empty or deleted, /release falls back to the PR title and flags the PR for a human to check. Don't edit CHANGELOG.md in this PR.
-->

## Proof

<!-- Before/after screenshots or a short clip for anything user-visible; otherwise one line on why not (e.g. CI only).
Native app UI: paste what `cmux-ci capture <head sha> --state <scene:NAME|tour:NAME> --pr <N>` prints (real light and dark stills of a fleet build), add the media-tour label, or write `No capture: <why>`. The pr-capture-check job fails a native UI change without one. -->

<!-- Performance change (the perf label, or a perf word in the title or description)? Record the deltas so we can look back on them: add a section like the one below, with before and after from the same harness (or, under that heading, `No perf numbers: <why>`). The pr-perf-section-check job fails a perf PR without one; docs-only PRs are exempt.

## Performance

| metric | before | after | delta | harness or run link |
| --- | --- | --- | --- | --- |
| sidebar open p50 | 182 ms | 113 ms | -38% | https://github.com/manaflow-ai/cmux/actions/runs/... |
-->

## Checklist

- [ ] Behavior changes have added or updated tests, or Testing says why not
- [ ] UI, settings, menu, schema, help-text or user-facing docs change: [localization audited](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-localization/SKILL.md), and the result is stated above
- [ ] New or changed v2 socket method allowlisted for `cmux ssh`: the [relay authorization questions](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-socket-policy/references/remote-relay-authorization.md) are answered above
- [ ] iOS connectivity, auth, lifecycle, workspace action, terminal I/O or mobile RPC contract change: [deterministic soak coverage](https://github.com/manaflow-ai/cmux/blob/main/docs/ios-connectivity-soak.md) updated, or explained why existing coverage still applies, with the affected workload result recorded
- [ ] User-facing docs updated if needed
- [ ] Reviewed with a subagent before merge ([cmux-review](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-review/SKILL.md)), and all bot and human review comments resolved
