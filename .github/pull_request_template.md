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

## Demo Video

For UI or behavior changes, include a short demo video or screenshots (GitHub upload, Loom, or other direct link).

- Video URL or attachment:

<!--
## Review Trigger (Copy/Paste as PR comment)

```text
@codex review
@coderabbitai review
@greptileai review
@cubic-dev-ai review
```
-->

## Checklist

- [ ] Behavior changes have added or updated tests, or Testing says why not
- [ ] UI, settings, menu, schema, help-text or user-facing docs change: [localization audited](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-localization/SKILL.md), and the result is stated above
- [ ] New or changed v2 socket method allowlisted for `cmux ssh`: the [relay authorization questions](https://github.com/manaflow-ai/cmux/blob/main/CLAUDE.md#remote-cli-relay-authorization-ghsa-9vmv-3hjw-j28c) are answered above
- [ ] iOS connectivity, auth, lifecycle, workspace action, terminal I/O or mobile RPC contract change: [deterministic soak coverage](https://github.com/manaflow-ai/cmux/blob/main/docs/ios-connectivity-soak.md) updated, or explained why existing coverage still applies, with the affected workload result recorded
- [ ] Docs and changelog updated if needed
- [ ] Bot reviews requested after the latest commit (paste the commented-out Review Trigger block from this template as a PR comment, or equivalent), and all bot and human review comments resolved
