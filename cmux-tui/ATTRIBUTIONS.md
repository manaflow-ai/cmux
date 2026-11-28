# Third-party attributions

## herdr

- Project: https://github.com/ogulcancelik/herdr (also published as
  https://github.com/herdrdev/herdr; the same repository)
- License: Apache-2.0 (upstream ships a LICENSE file and no NOTICE file; a
  copy is included at
  `bindings/examples/rust-agent-screen-detection/manifests/LICENSE`)
- Upstream pin: commit `2563803dca97c040beaf3dc3acdcb5a3221b4238` (herdr
  0.9.3, manifest engine version 3), recorded with per-file hashes in
  `bindings/examples/rust-agent-screen-detection/HERDR_UPSTREAM.toml`.
  `scripts/cmux-next/herdr-sync.py check` verifies it on every push, and the
  scheduled `herdr-upstream-drift` workflow reports upstream changes.

Derived material and vendored material:

- `bindings/examples/rust-agent-screen-detection/manifests/*.toml`: all 22
  manifests are byte-identical to herdr's `src/detect/manifests/` at the pin.
  None carries a local cmux patch (`HERDR_PATCHES.toml` lists none). Never
  refresh these files from herdr's update endpoint; re-vendor them with
  `herdr-sync.py sync`, which reapplies documented patches or fails.
- `bindings/examples/rust-agent-screen-detection/src/manifest.rs`: the
  manifest engine (rule grammar, region extraction, gate evaluation,
  validation limits), ported from `src/detect/manifest.rs`; its semantics
  were rechecked at the pin.
- `bindings/examples/rust-agent-screen-detection/src/{detect.rs,scanner.rs}`:
  detection semantics (state model, edge-triggered transitions,
  foreground-process identification, quiescence sampling) derived from
  `src/detect/mod.rs`, `src/pane/agent_detection.rs`, and `src/pane.rs`.
  These files are a userland plugin. Herdr's first-acquisition OSC retention
  fix (`82e6a80eb3ae39fb3d3ebd4d1fed19389767e605`) is adapted as a local
  output-revision fence for replacement agents. Core only supervises the
  process and folds its generic events.
- `bindings/examples/rust-agent-screen-detection/src/background_agent.rs`:
  keeping a suspended or backgrounded agent's identity, adapted from herdr's
  `src/pane/background_agent.rs` and platform process-liveness functions at
  `950d012cf0cfd17737b4fff2f4982210b50b5794`.
- `bindings/examples/rust-agent-screen-detection/src/process.rs` and
  `src/process/launchers.rs`: bounded foreground process-group discovery and
  wrapper handling derived from herdr's platform and detector modules,
  including the Pi bundled-launcher correction, the Hermes Python installer
  signature, Letta interactivity, Cline's `.cline` launcher, and the Kimi and
  omp package launchers. Manaflow adds platform fallbacks, stricter candidate
  filtering, attached runtime-mode parsing, positional-argument boundaries,
  direct shell-script parsing, shell-word unescaping, runtime-specific shell
  invocation-mode checks, Python boolean/exit/value option boundaries,
  attached-versus-separate option handling, and bounded `/proc` streaming.
  The Python distinctions are a local correctness improvement over the
  inherited option list: `-S` is boolean, documented help aliases (`-?`,
  `-VV`) terminate, and help/version/hash options cannot expose following
  tokens as agent executables. Unsupported attached long options fail closed
  before they can consume a later runtime mode flag.
- `crates/cmux-tui-core/src/terminal_metadata.rs`: OSC string framing adapted
  from herdr's `src/pane/osc.rs`. Manaflow adds lead-specific UTF-8
  continuation validation and malformed-sequence recovery before C1 framing.
  Core retains only generic bounded OSC 9 progress metadata; it has no agent
  or roster policy.
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
- The plugin's `manifests/SHA256SUMS` record is checked before bundled
  compilation to catch accidental drift. It is not a cryptographic release
  signature for remote updates.

The list of upstream commits ported and not applicable at this pin, with the
reason for each, is in
`bindings/examples/rust-agent-screen-detection/ATTRIBUTIONS.md`. Application,
client, graphics, PTY input, hook-integration and Windows commits are outside
detector behavior and are not copied. A standalone release must define and
test SDK endpoint-generation compatibility before it promises binary upgrades
across host versions. Review the Windows changes before publishing a Windows
package.

Files that port herdr logic carry a header comment naming the upstream
file and the modifications.
