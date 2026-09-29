<!-- Before drafting or revising this description, read ../STYLE.md. Lead with the problem and the resulting behavior, keep it proportional, and delete any section or checklist line that does not apply. -->

## Summary

<!-- The concrete problem, and what a user or API caller can do after this change. Explain as much of the mechanism as a reviewer needs to assess it; link deeper design or implementation detail. -->

## Testing

<!--
Say what ran, what passed, and what that establishes. Keep these apart:
- Tests added vs. tests executed. Name the command or CI lane that ran them; a green job whose tests were skipped is not coverage.
- Compiled vs. ran vs. checked live in a tagged build.
- Anything still unverified, stated once, next to the claim it limits.
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

## Demo Video

For UI or behavior changes, include a short demo video or screenshots (GitHub upload, Loom, or other direct link).

- Video URL or attachment:

## Checklist

- [ ] Behavior changes have added or updated tests, or Testing says why not
- [ ] An independent reviewer will approve this pull request before merge, or the Summary/Testing section records the specific exception, approver, and reason for merging without approval
- [ ] UI, settings, menu, schema, help-text or user-facing docs change: [localization audited](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-localization/SKILL.md), and the result is stated above
- [ ] New or changed v2 socket method allowlisted for `cmux ssh`: the [relay authorization questions](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-socket-policy/references/remote-relay-authorization.md) are answered above
- [ ] iOS connectivity, auth, lifecycle, workspace action, terminal I/O or mobile RPC contract change: [deterministic soak coverage](https://github.com/manaflow-ai/cmux/blob/main/docs/ios-connectivity-soak.md) updated, or explained why existing coverage still applies, with the affected workload result recorded
- [ ] Changes to `.github/workflows/`, `/ios/Config/`, or `/ios/scripts/upload-testflight.sh` have the required CODEOWNER review before merge
- [ ] User-facing docs updated if needed
- [ ] Reviewed with a subagent before merge ([cmux-review](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-review/SKILL.md)), and all bot and human review comments resolved
