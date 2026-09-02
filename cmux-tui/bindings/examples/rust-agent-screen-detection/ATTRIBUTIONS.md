# Attributions

The files under `manifests/` are derived from the herdr project:

* Project: https://github.com/herdrdev/herdr
* Detector source reference revision: `7b675f42af35508eab66ac42fe1598628597a893`
* Pi bundled-launcher correction: `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`
* Manifest snapshot revision: `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
* First-acquisition OSC retention: `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605`
* Included manifest fixes: Claude MCP elicitation `f807b697353cfa00aa912c7cde4830e863001cf5`,
  Claude background-shell state `987b070fbfa187e85009b45cd7e208fc6175ff6a`,
  Codex weak-blocker scope `f457cff4f2648eee85d176f8a41861241d4e8428`, and
  Copilot background-agent activity `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`.
* License: Apache-2.0, reproduced in `manifests/LICENSE`
* Unchanged vendored material: 19 of the 21 `manifests/*.toml` files, copied
  from `src/detect/manifests/` at the manifest snapshot revision. `claude.toml`
  is byte-identical to upstream commit `987b070fbfa187e85009b45cd7e208fc6175ff6a`.
  `grok.toml` is the local correction described below.
* Local correction: `manifests/grok.toml` keeps a static custom title from
  masking Grok's idle OSC progress and adds an explicit spinner rule. Its
  numeric patch version is `2026.07.16.2.1`; the upstream file is
  `2026.07.16.2`.
* Changes: cmux pins the files locally and validates them with its own
  bounded manifest engine. It does not use herdr's network update path.

The checked-in manifests/SHA256SUMS record is verified before bundled
compilation. It detects accidental drift, not a cryptographic release
signature for remote updates.

The attribution and capability audit was rerun against herdr's agent-surface
revision `987b070fbfa187e85009b45cd7e208fc6175ff6a` after the pinned snapshot.
The package adapts and tests the exact Pi bundled CLI path correction in
`b1ff4582e9688f52ffb943cfa8bee4871ae122e4`. It also vendors and tests the
Claude background-shell state correction in
`987b070fbfa187e85009b45cd7e208fc6175ff6a`. The audit found the
first-acquisition OSC retention fix in
`82e6a80eb3ae39fb3d3ebd4d1fed19389767e605`; `src/detect.rs` ports that policy
with a local revision fence because the generic host API cannot clear OSC
state. It also found foreground group-leader CWD selection in
`3a3792622e59c7f2dc20f9c0236167161e4a5035`; cmux's generic
`foreground_cwd` resource already resolves the group leader, so no
herdr-specific CWD code is copied. Later upstream commits
`207be3c771d281baae6e5fa0fb74be9a056e97a2`,
`5158adab10b6dcfea9370782043392f80fa0643c`,
`5616196942cbe752cc0659b9bd0fb616b2a6ed5c`,
`da8c7b05f9ef7898cfb7494989df8a533b947bb9`, `99c23cd1ea7468bd3661f6483c7105396503b417`,
`0032c3b42751b6da9c5b1a91546b3c1a425d67f1`, and
`18e69891dca486d669a584facd80644bb51f54a2` change Windows launch, process
environment, process-job, input handling, remote multiline paste, OpenSSH
mouse input, or the application/client shell rendering architecture. The
post-audit multi-client tab-view change
`6c0bb273d5d5405a00985621b17e36f8b4d64609` and the reliable delayed-prompt
change `8633a398e653eee47b375c963996c78a8a14aa48` change host/client and PTY
input behavior, not this detector. These changes are not detector logic and
are not copied. This package has no Windows SDK transport, native process
backend, launch path, or input path, so those files are not copied. A
standalone release must define and test SDK endpoint-generation compatibility
before it promises upgrades across host versions. Recheck these upstream
areas before publishing a Windows package.

The herdr repository tip checked on 2026-09-02 is
`5a2dee700eeeea68267a4d16777307632f77172f`. The commits after the
agent-surface revision change client mouse selection and Windows worktree
removal; they do not change `src/detect` or the manifests. The agent-surface
revision is the reproducible capability-audit pin.

The original cmux portions of this package are licensed under MIT. The full
text is in `LICENSE-MIT`. The Apache-2.0 text for the derived herdr material is
in `manifests/LICENSE`.

The detector engine in `src/manifest.rs` is adapted from herdr's
`src/detect/manifest.rs` semantics. It keeps the attribution above and adds
bounded recursion, case-normalized process aliases, and a public plugin
boundary. Its Claude background-shell regression fixtures are adapted from
herdr's `src/detect/manifest/tests.rs` at
`987b070fbfa187e85009b45cd7e208fc6175ff6a`.

The package does not copy herdr's application, API server, sound assets, or
other multiplexer code. Only the listed detector files and manifests contain
derived herdr material.

`src/process.rs` adapts herdr's `src/platform/{linux,macos}.rs` and
`src/detect/mod.rs` foreground process-group and wrapper discovery. It adds
bounded traversal and `/proc` streaming, safer path candidates, attached
runtime-mode parsing, positional-argument boundaries, direct shell-script and
shell-word parsing, runtime-specific shell invocation-mode checks, Python
boolean/exit/value option boundaries, attached-versus-separate option handling,
and an explicit Linux child-group fallback. The Python option distinctions are
a local correctness improvement:
`-S` does not consume the script, documented help aliases (`-?`, `-VV`)
terminate, and help/version/hash options cannot expose following tokens as
agent executables. Its strict Pi package-entrypoint check includes herdr's
Windows fix
from commit `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`; the check is adapted to
the replaceable manifest catalog. The reference package targets macOS and
Linux because its Rust SDK transport is Unix-only. A Windows publication needs
a Windows-capable SDK transport and process backend; it must not claim a
public-process fallback.

`src/detect.rs` adapts herdr's `src/detect/mod.rs` and
`src/pane/agent_detection.rs` debounce, identity-edge, miss-confirmation, and
flowing-output signals. The one-second max-evaluation pacer, deterministic
activity-expiry debt, and same-name process-group replacement edge are
manaflow changes. Herdr's first-acquisition OSC retention fix from
`82e6a80eb3ae39fb3d3ebd4d1fed19389767e605` is adapted as a local
output-revision fence for replacement agents; it keeps that generic host
metadata from being attributed across an agent identity edge while preserving
evidence emitted before the first process probe.

`src/manifest_update.rs` follows herdr's `src/detect/manifest_update.rs`
versioned update and status concepts.
Its explicit-only network policy, HTTPS checks, response bounds, independent
per-agent failures, and atomic cache writes are manaflow changes.
