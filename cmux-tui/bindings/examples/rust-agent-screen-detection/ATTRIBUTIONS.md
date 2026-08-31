# Attributions

The files under `manifests/` are derived from the herdr project:

* Project: https://github.com/herdrdev/herdr
* Source revision: `7b675f42af35508eab66ac42fe1598628597a893`
* License: Apache-2.0, reproduced in `manifests/LICENSE`
* Derived material: `manifests/*.toml`, based on `src/detect/manifests/`
* Changes: cmux pins the files locally and validates them with its own
  bounded manifest engine. It does not use herdr's network update path.

The detector engine in `src/manifest.rs` is adapted from herdr's
`src/detect/manifest.rs` semantics. It keeps the attribution above and adds
bounded recursion, case-normalized process aliases, and a public plugin
boundary.

The package does not copy herdr's application, API server, sound assets, or
other multiplexer code. Only the listed detector files and manifests contain
derived herdr material.

`src/process.rs` adapts herdr's `src/platform/{linux,macos,windows}.rs` and
`src/detect/mod.rs` foreground process-group and wrapper discovery. It adds
bounded traversal, safer path candidates, and a fallback to the public cmux
process response. The current package has native deep inspection on Linux and
macOS; Windows uses the public one-process fallback until a Windows backend is
added.

`src/detect.rs` adapts herdr's `src/detect/mod.rs` and
`src/pane/agent_detection.rs` debounce, identity-edge, miss-confirmation, and
flowing-output signals. The one-second max-evaluation pacer, deterministic
activity-expiry debt, and same-name process-group replacement edge are
manaflow changes.

`src/manifest_update.rs` follows herdr's `src/detect/manifest_update.rs`
versioned update and status concepts.
Its explicit-only network policy, HTTPS checks, response bounds, independent
per-agent failures, and atomic cache writes are manaflow changes.
