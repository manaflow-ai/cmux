# Attributions

The files under `manifests/` are derived from the herdr project:

* Project: https://github.com/herdrdev/herdr
* Source revision: `7b675f42af35508eab66ac42fe1598628597a893`
* License: Apache-2.0, reproduced in `manifests/LICENSE`
* Unchanged vendored material: 20 of the 21 `manifests/*.toml` files, copied
  from `src/detect/manifests/`
* Local correction: `manifests/grok.toml` keeps a static custom title from
  masking Grok's idle OSC progress and adds an explicit spinner rule. Its
  numeric patch version is `2026.07.16.2.1`; the upstream file is
  `2026.07.16.2`.
* Changes: cmux pins the files locally and validates them with its own
  bounded manifest engine. It does not use herdr's network update path.

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
fallback. The reference package targets macOS and Linux because its Rust SDK
transport is Unix-only. A Windows publication needs a Windows-capable SDK
transport and process backend; it must not claim a public-process fallback.

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
