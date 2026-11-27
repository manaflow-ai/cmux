# Secret rules

`acpmux::secret_scan` masks secrets in text the daemon shows elsewhere (hq#2509). Its rules come from here:

- `gitleaks.toml` is gitleaks' default rule set (MIT), pinned to `v8.30.1` and unmodified.
- `labels.toml` gives each rule's mask: `[GitHub Personal Access Token]`, `[Slack Bot token]`.
- `noseyparker-examples.json` is Nosey Parker's rule examples (Apache-2.0, `v0.24.0`), test data only, XORed and base64-encoded so no committed file trips a secret scanner or GitHub push protection.

Refresh all three (it downloads rule files and never touches a secret):

```bash
bun cmux-tui/crates/acpmux/rules/secrets/refresh.ts v8.30.1 v0.24.0
```

Then check the labels it prints, and run `cargo test -p acpmux --lib secret_scan` on a Testbox or CI. The test fails when a rule stops compiling, a rule has no label, or recall on Nosey Parker's examples falls. See `../../../../ATTRIBUTIONS.md` for licenses.
