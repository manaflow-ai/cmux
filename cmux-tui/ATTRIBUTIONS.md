# Third-party attributions

## herdr

- Project: https://github.com/herdrdev/herdr
- License: Apache-2.0 (upstream ships a LICENSE file and no NOTICE file; a
  copy is included at
  `bindings/examples/rust-agent-screen-detection/manifests/LICENSE`)
- Pinned commit: `7b675f42af35508eab66ac42fe1598628597a893`

Derived material and unchanged vendored material:

- `bindings/examples/rust-agent-screen-detection/manifests/*.toml`: the 21
  agent-detection manifests, vendored unchanged from `src/detect/manifests/`.
  Never refresh them from herdr's update endpoint; re-vendor and bump the pin
  instead.
- `bindings/examples/rust-agent-screen-detection/src/manifest.rs`: the
  manifest engine (rule grammar, region extraction, gate evaluation,
  validation limits), ported from `src/detect/manifest.rs`.
- `bindings/examples/rust-agent-screen-detection/src/{detect.rs,scanner.rs}`:
  detection semantics (state model, edge-triggered transitions,
  foreground-process identification, quiescence sampling) derived from
  `src/detect/mod.rs`, `src/pane/agent_detection.rs`, and `src/pane.rs`.
  These files are a userland plugin. Core only supervises the process and
  folds its generic events.
- `bindings/examples/rust-agent-screen-detection/src/process.rs`: bounded
  foreground process-group discovery and wrapper handling derived from
  herdr's platform and detector modules, with platform fallbacks and stricter
  candidate filtering added by manaflow.
- `crates/cmux-tui-core/src/terminal_metadata.rs`: OSC string framing adapted
  from herdr's `src/pane/osc.rs`. Core retains only generic bounded OSC 9
  progress metadata; it has no agent or roster policy.
- `bindings/examples/rust-agent-screen-detection/src/manifest_update.rs`:
  explicit catalog and cache status concepts derived from herdr's update
  surface. Network access, URL validation, atomic writes, and version policy
  are a new manaflow implementation and never run during daemon startup.
- `crates/cmux-tui/src/sidebar_projection.rs` (`agent_attention`) and the
  agents-view rendering in `crates/cmux-tui/src/ui/{sidebar.rs,rail.rs}`:
  the two-line row and header layout follow `src/app/agent_view.rs` and
  herdr's agents-panel design. cmux currently orders rows by blocked,
  working, then idle, with newest transitions first inside each bucket. The
  herdr idle-unseen seen bit is intentionally not copied because it is
  client-owned presentation state; the deliberate exclusion is listed in
  `spec/plugins.md`.

Files that port herdr logic carry a header comment naming the upstream
file and the modifications.
