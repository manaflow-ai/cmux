# Attributions

The files under `manifests/` are derived from the herdr project:

* Project: https://github.com/herdrdev/herdr
* Detector source reference revision: `7b675f42af35508eab66ac42fe1598628597a893`
* Pi bundled-launcher correction: `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`
* Manifest snapshot revision: `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
* License: Apache-2.0, reproduced in `manifests/LICENSE`
* Unchanged vendored material: 17 of the 21 `manifests/*.toml` files, copied
  from `src/detect/manifests/` at the manifest snapshot revision. The Claude,
  Codex, and GitHub Copilot files include the upstream fixes in that snapshot.
* Local correction: `manifests/grok.toml` keeps a static custom title from
  masking Grok's idle OSC progress and adds an explicit spinner rule. Its
  numeric patch version is `2026.07.16.2.1`; the upstream file is
  `2026.07.16.2`.
* Changes: cmux pins the files locally and validates them with its own
  bounded manifest engine. It does not use herdr's network update path.

The attribution and capability audit was rerun against herdr revision
`99c23cd1ea7468bd3661f6483c7105396503b417` after the pinned snapshot. It found
no newer detector or manifest change to copy. Later upstream commits
`5158adab10b6dcfea9370782043392f80fa0643c`,
`5616196942cbe752cc0659b9bd0fb616b2a6ed5c`,
`da8c7b05f9ef7898cfb7494989df8a533b947bb9`, and
`99c23cd1ea7468bd3661f6483c7105396503b417` change Windows launch, process
environment, process-job, or input handling. This package has no Windows SDK
transport, native process backend, launch path, or input path, so those files
are not copied. Recheck them before publishing a Windows package.

The original cmux portions of this package are licensed under MIT. The full
text is in `LICENSE-MIT`. The Apache-2.0 text for the derived herdr material is
in `manifests/LICENSE`.

The detector engine in `src/manifest.rs` is adapted from herdr's
`src/detect/manifest.rs` semantics. It keeps the attribution above and adds
bounded recursion, case-normalized process aliases, and a public plugin
boundary.

The package does not copy herdr's application, API server, sound assets, or
other multiplexer code. Only the listed detector files and manifests contain
derived herdr material.

`src/process.rs` adapts herdr's `src/platform/{linux,macos}.rs` and
`src/detect/mod.rs` foreground process-group and wrapper discovery. It adds
bounded traversal, safer path candidates, and an explicit Linux child-group
fallback. Its strict Pi package-entrypoint check includes herdr's Windows fix
from commit `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`; the check is adapted to
the replaceable manifest catalog. The reference package targets macOS and
Linux because its Rust SDK transport is Unix-only. A Windows publication needs
a Windows-capable SDK transport and process backend; it must not claim a
public-process fallback.

`src/detect.rs` adapts herdr's `src/detect/mod.rs` and
`src/pane/agent_detection.rs` debounce, identity-edge, miss-confirmation, and
flowing-output signals. The one-second max-evaluation pacer, deterministic
activity-expiry debt, and same-name process-group replacement edge are
manaflow changes. The output-revision fence for retained OSC title and
progress metadata is also a manaflow change; it keeps that generic host
metadata from being attributed across an agent identity edge.

`src/manifest_update.rs` follows herdr's `src/detect/manifest_update.rs`
versioned update and status concepts.
Its explicit-only network policy, HTTPS checks, response bounds, independent
per-agent failures, and atomic cache writes are manaflow changes.
