# Third-party attributions

## herdr

- Project: https://github.com/herdrdev/herdr
- License: Apache-2.0 (upstream ships a LICENSE file and no NOTICE file; a
  copy is vendored at `vendor/herdr-manifests/LICENSE`)
- Pinned commit: `7b675f42af35508eab66ac42fe1598628597a893`

Derived material, in each case modified by manaflow:

- `vendor/herdr-manifests/*.toml`: the 21 agent-detection manifests,
  vendored verbatim from `src/detect/manifests/` (per-file modifications,
  if any, are noted in that directory's README). Never refreshed from
  herdr's update endpoint; re-vendor and bump the pin instead.
- `crates/cmux-tui-core/src/screen_detect/manifest.rs`: the manifest
  engine (rule grammar, region extraction, gate evaluation, validation
  limits), ported from `src/detect/manifest.rs`.
- `crates/cmux-tui-core/src/screen_detect/{mod.rs,scanner.rs}`: detection
  semantics (state model, edge-triggered transitions, foreground-process
  identification, quiescence sampling) derived from `src/detect/mod.rs`
  and herdr's poller design.
- `crates/cmux-tui/src/sidebar_projection.rs` (`agent_priority`) and the
  agents-view rendering in `crates/cmux-tui/src/ui/{sidebar.rs,rail.rs}`:
  the priority order (blocked > idle-unseen > working > idle-seen >
  unknown), the seen-bit semantics, and the two-line row / header layout
  follow `src/app/agent_view.rs` and herdr's agents panel design.

Files that port herdr logic carry a header comment naming the upstream
file and the modifications.
