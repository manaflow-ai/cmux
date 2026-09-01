# Third-party attributions

## herdr

- Project: https://github.com/herdrdev/herdr
- License: Apache-2.0 (upstream ships a LICENSE file and no NOTICE file; a
  copy is included at
  `bindings/examples/rust-agent-screen-detection/manifests/LICENSE`)
- Detector source reference commit: `7b675f42af35508eab66ac42fe1598628597a893`
- Manifest snapshot commit: `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`

Derived material and vendored material:

- `bindings/examples/rust-agent-screen-detection/manifests/*.toml`: 17
  manifests are unchanged from the manifest snapshot's
  `src/detect/manifests/`; Claude, Codex, and GitHub Copilot include the
  upstream fixes present in that snapshot. `grok.toml` carries a documented
  cmux precedence correction. Never refresh them from herdr's update endpoint.
  Re-vendor the files from the exact snapshot commit and reapply the Grok patch
  when changing the pin.
- `bindings/examples/rust-agent-screen-detection/src/manifest.rs`: the
  manifest engine (rule grammar, region extraction, gate evaluation,
  validation limits), ported from `src/detect/manifest.rs`.
- `bindings/examples/rust-agent-screen-detection/src/{detect.rs,scanner.rs}`:
  detection semantics (state model, edge-triggered transitions,
  foreground-process identification, quiescence sampling) derived from
  `src/detect/mod.rs`, `src/pane/agent_detection.rs`, and `src/pane.rs`.
  These files are a userland plugin. The output-revision fence for retained
  OSC metadata is a cmux adaptation. Core only supervises the process and
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
  cache invalidation against cmux's terminal topology and the stable
  tree-order tie break are manaflow additions. The herdr idle-unseen seen bit
  is intentionally not copied because it is client-owned presentation state;
  the deliberate exclusion is listed in `spec/plugins.md`.
- `bindings/examples/rust-agent-screen-detection/manifests/grok.toml`: the
  local `2026.07.16.2.1` patch gives idle OSC progress precedence over a
  generic custom title and keeps explicit braille-spinner activity stronger.

Files that port herdr logic carry a header comment naming the upstream
file and the modifications.
