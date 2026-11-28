# Attributions

This package contains material derived from the herdr project:

* Project: https://github.com/ogulcancelik/herdr (also published as
  https://github.com/herdrdev/herdr; both names are the same repository)
* License: Apache-2.0. Upstream ships a `LICENSE` file and no `NOTICE` file.
  The license text is reproduced unchanged in `manifests/LICENSE`.
* Upstream pin: commit `2563803dca97c040beaf3dc3acdcb5a3221b4238` (herdr
  0.9.3, manifest engine version 3), synced 2026-10-08. `HERDR_UPSTREAM.toml`
  records the pin, the upstream sha256 of every vendored manifest and of the
  upstream engine sources this port follows.

The original cmux portions of this package are licensed under
GPL-3.0-or-later; the full text is in `LICENSE`. Only the files listed below
contain herdr-derived material, and each carries a header that names the
upstream file, the commit and the cmux changes. The package does not copy
herdr's application, API server, integrations, sound assets or other
multiplexer code.

## Vendored manifests

`manifests/*.toml` are byte-identical to herdr's `src/detect/manifests/` at
the pin. No file carries a local patch: `HERDR_PATCHES.toml` documents the
mechanism and lists none. The Grok precedence correction that cmux used to
patch in (idle OSC progress outranks a generic custom title, an explicit
spinner title outranks retained idle progress, and the blank braille code
point is not a spinner) is covered by upstream Grok `2026.10.05.1`, so the
patch was dropped.

`manifests/SHA256SUMS` and `HERDR_UPSTREAM.toml` are verified offline by
`python3 -I scripts/cmux-next/herdr-sync.py check` on every push, and the
plugin's provenance test checks `SHA256SUMS` before the bundled set compiles.
These records detect accidental drift; they are not a release signature for
remote updates. `scripts/cmux-next/herdr-sync.py sync` re-vendors the files
from a herdr checkout with `git show`, never the update endpoint. The daily
`herdr-upstream-drift` workflow reports upstream changes in one issue.

## Adapted sources

* `src/manifest.rs`: the manifest engine (rule grammar, regions, gates,
  validation limits), ported from herdr `src/detect/manifest.rs` at
  `7b675f42af35508eab66ac42fe1598628597a893`. Rechecked at the pin: upstream
  only moved compiled rules behind an `Arc` and removed
  `should_skip_state_update` (cmux already evaluates skip rules with the OSC
  inputs). cmux adds bounded recursion and loading, case-normalized process
  aliases, explain output and a public plugin boundary. Its Claude
  background-shell fixtures are adapted from herdr's
  `src/detect/manifest/tests.rs` at `987b070fbfa187e85009b45cd7e208fc6175ff6a`.
* `src/process.rs` and `src/process/launchers.rs`: foreground process-group
  discovery and wrapper identification, adapted from herdr's
  `src/platform/{linux,macos}.rs` and `src/detect/mod.rs`. At the pin this
  includes the Pi bundled-launcher correction
  (`b1ff4582e9688f52ffb943cfa8bee4871ae122e4`), the Hermes Python installer
  signature (e35f3937), Letta interactivity (fc1cb77f), Cline's hidden
  `.cline` launcher and the rule that another program's arguments are not an
  identity (f3cbe03f), the Kimi and omp package launchers (63ea2314,
  cd8306d7) and the matched agent pid (950d012c). cmux adds bounded
  traversal and `/proc` streaming, attached runtime-mode parsing,
  positional-argument boundaries, shell-word and per-shell invocation-mode
  parsing, Python boolean/exit/value option boundaries, attached-versus-
  separate option handling, an explicit Linux child-group fallback, and
  identity through the replaceable manifest catalog instead of a closed enum.
  The Python option distinctions are a local correctness improvement: `-S`
  does not consume the script, documented help aliases (`-?`, `-VV`)
  terminate, and help/version/hash options cannot expose following tokens as
  agent executables.
* `src/background_agent.rs`: keeping a suspended or backgrounded agent's
  identity, adapted from herdr `src/pane/background_agent.rs` and the
  `process_start_token` / `live_pane_process_group` functions of
  `src/platform/{linux,macos}.rs` at `950d012cf0cfd17737b4fff2f4982210b50b5794`.
  cmux uses manifest ids, and leaves the held-agent replacement case to the
  scanner's process-group edge.
* `src/detect.rs` and `src/scanner.rs`: debounce, identity-edge,
  miss-confirmation and flowing-output signals adapted from herdr
  `src/detect/mod.rs`, `src/pane/agent_detection.rs` and `src/pane.rs` at
  `7b675f42af35508eab66ac42fe1598628597a893`. The first-acquisition OSC
  retention fix (`82e6a80eb3ae39fb3d3ebd4d1fed19389767e605`) is adapted as a
  local output-revision fence because the generic host API cannot clear OSC
  state. The one-second evaluation pacer, activity-expiry debt and same-name
  process-group replacement edge are cmux changes.
* `src/manifest_update.rs`: versioned update and status concepts from herdr
  `src/detect/manifest_update.rs`. The explicit-only network policy, HTTPS
  checks, response bounds, per-agent failures and atomic cache writes are cmux
  changes.
* `src/herdr_parity_tests.rs` and `src/background_agent.rs` tests adapt herdr
  test cases at the pin. `tests/fixtures/hermes-installer-process-info-4910.json`
  is herdr's redacted reporter capture, copied unchanged.

## Upstream commits reviewed for the 2026-10-08 sync

Commits on `src/detect`, `src/pane/agent_detection.rs` and `src/pane/osc.rs`
since the previous audit pin `987b070fbfa187e85009b45cd7e208fc6175ff6a`.

Ported: fabcab10 (agy dialogs and mid-turn work; agy and Grok background work
is idle), 07e3840b (Codex trust layout and title idle, Pi spinner line),
7237703d (Codex mention popups), 7df919d0 (Grok custom or disabled OSC
signals), e35f3937 (Hermes Python installer), fc1cb77f (Letta manifest and
interactivity), f3cbe03f (Cline manifest and launchers), 950d012c (suspended
or backgrounded agents keep their identity), 63ea2314 and cd8306d7 (Kimi and
omp package paths). Already vendored before this sync: 29f9f405, a3a1c94e,
7fe5a7cd, 7e51b283, e3a46f4f, a05c4038, 4b5e9bda, 987651a7.

Not applicable: 9c96f7dd (its Codex manifest change was reverted by 07e3840b;
the Codex prompt observation feeds herdr's hook integration), cce57bc3 and
fe935882 (text reuse for unidentified panes; this plugin never reads an
unidentified terminal's screen), the `Arc` rule sharing in `manifest.rs`
(this engine compiles each manifest once per set), 2552d101 and 90b0e40a
(agent resume and hook handoff in the application), 0d5d6f1f and 7201907b
(upstream tests only), c411883e and 309749ad (`osc.rs` graphics and Droid
scrollback handling; OSC parsing is generic host terminal code, not this
plugin), 8c8cb49c and the other Windows process-environment, input and launch
commits (this package has no Windows transport or process backend; recheck
before a Windows publication). Not ported yet: bafbc094 (on WSL, skip
`/proc/<pid>/cmdline` reads of exiting processes that can block); this
package does not claim WSL support.
