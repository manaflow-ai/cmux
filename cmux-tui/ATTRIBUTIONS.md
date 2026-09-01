# Third-party attributions

## herdr

- Project: https://github.com/herdrdev/herdr
- License: Apache-2.0 (upstream ships a LICENSE file and no NOTICE file; a
  copy is included at
  `bindings/examples/rust-agent-screen-detection/manifests/LICENSE`)
- Detector source reference commit: `7b675f42af35508eab66ac42fe1598628597a893`
- Pi bundled-launcher correction commit: `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`
- Manifest snapshot commit: `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- First-acquisition OSC retention commit: `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605`

Derived material and vendored material:

- `bindings/examples/rust-agent-screen-detection/manifests/*.toml`: 20
  manifests are unchanged from the manifest snapshot's
  `src/detect/manifests/`; `grok.toml` carries a documented cmux precedence
  correction. Never refresh them from herdr's update endpoint.
  Re-vendor the files from the exact snapshot commit and reapply the Grok patch
  when changing the pin.
- `bindings/examples/rust-agent-screen-detection/src/manifest.rs`: the
  manifest engine (rule grammar, region extraction, gate evaluation,
  validation limits), ported from `src/detect/manifest.rs`.
- `bindings/examples/rust-agent-screen-detection/src/{detect.rs,scanner.rs}`:
  detection semantics (state model, edge-triggered transitions,
  foreground-process identification, quiescence sampling) derived from
  `src/detect/mod.rs`, `src/pane/agent_detection.rs`, and `src/pane.rs`.
  These files are a userland plugin. Herdr's first-acquisition OSC retention
  fix (`82e6a80eb3ae39fb3d3ebd4d1fed19389767e605`) is adapted as a local
  output-revision fence for replacement agents. Core only supervises the
  process and folds its generic events.
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

The capability audit was rerun against herdr revision
`18e69891dca486d669a584facd80644bb51f54a2`. The first-acquisition OSC
retention fix in `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605` is adapted in the
userland tracker with a local revision fence. The foreground group-leader CWD
fix in `3a3792622e59c7f2dc20f9c0236167161e4a5035` is already covered by the
generic `foreground_cwd` resource, so no herdr-specific CWD policy is copied.
The shell-render refactor in
`207be3c771d281baae6e5fa0fb74be9a056e97a2` is application/client architecture,
not detector behavior, and is not copied. Later upstream commits
`5158adab10b6dcfea9370782043392f80fa0643c`,
`5616196942cbe752cc0659b9bd0fb616b2a6ed5c`,
`da8c7b05f9ef7898cfb7494989df8a533b947bb9`, `99c23cd1ea7468bd3661f6483c7105396503b417`,
`0032c3b42751b6da9c5b1a91546b3c1a425d67f1`, and
`18e69891dca486d669a584facd80644bb51f54a2` are Windows launch, process
environment, process-job, input, remote multiline paste, or OpenSSH mouse
input changes. They are outside this Unix-only reference package and must be
reviewed before Windows support is published.

Files that port herdr logic carry a header comment naming the upstream
file and the modifications.
