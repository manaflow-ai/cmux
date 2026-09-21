# Herdr-style agent detection handoff

Updated 2026-09-21. This file is an operational handoff for the next agent taking over the agent detection, journal, and provider icon work.

## Objective

Complete the Herdr-style userland plugin architecture for cmux-tui agent detection, feed structured provider identity and state into the journal, and render provider-aware icons in local tabs and Cloud sidebar rows. Finish the Freestyle snapshot and live end-to-end verification before merging.

The requested implementation is on:

- PR: https://github.com/manaflow-ai/cmux/pull/13299
- Author: `lawrencecchen`
- Branch: `feat-herdr-plugin-architecture`
- Worktree: `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-herdr-plugin-architecture`
- Exact HEAD: `829c0615e62b9a6427cd66df8dffe6f5276a324b`
- Worktree was clean after the implementation. Do not reset or discard changes.

## What is implemented

The PR is a large squashed integration of the earlier cmux-tui plugin work, Herdr-derived detection rules, journal plumbing, and icon consumers.

- A supervised userland journal-plugin boundary with manifests, namespaced events, lifecycle events, generation fences, startup repair, and replay-safe roster reduction.
- Rust reference detector at:
  `cmux-tui/bindings/examples/rust-agent-screen-detection/`
- Herdr-derived manifests, including the current Letta manifest and newer Claude, Codex, Cline, Grok, Kiro, and Pi rules.
- Detector ownership moved out of cmux-tui core.
- The plugin subscribes to terminal journal events and evaluates terminals whose output or lifecycle changed.
- Stable terminals block on journal events. There is no periodic detector heartbeat or terminal scanning loop in the new scanner path.
- Structured provider identity flows through hooks, journal folds, durable projections, `extra.agent`, resource snapshots, deltas, and Cloud TUI consumers.
- Local tab icons and Cloud sidebar terminal-row icons use structured provider identity. Title guessing was removed.
- SDKs and resource boundary descriptors were regenerated across C++, Go, Java, Python, Rust, TypeScript, and Zig.
- New and modified icon assets live under `Assets.xcassets/AgentIcons/`.

Useful code paths include:

- `cmux-tui/bindings/examples/rust-agent-screen-detection/src/scanner.rs`
- `cmux-tui/bindings/examples/rust-agent-screen-detection/src/detect.rs`
- `cmux-tui/bindings/examples/rust-agent-screen-detection/src/manifest.rs`
- `cmux-tui/bindings/examples/rust-agent-screen-detection/src/process.rs`
- `Sources/Surfaces/SurfaceResource+AgentIcon.swift`
- `Sources/Cloud/CloudTreeRowIcon.swift`
- `Sources/TerminalTabAgentIcon.swift`
- `cmux-tui/spec/plugins.md`
- `cmux-tui/spec/events.md`

The branch changes 228 files, with approximately 25,809 additions and 701 deletions.

## Herdr source

Latest Herdr master inspected:

`5a649142233631f8407b4099da0e8e78dfef8574`

A temporary checkout was at `/tmp/herdr-latest.4z0Fu2`. Attribution files still need an audit for stale pins or counts before merge.

## Verification already completed

Hosted exact-head verification run:

https://github.com/manaflow-ai/cmux/actions/runs/35569152879

The focused agent-filter tests, plugin tests, formatting, lint, MSRV, and the hosted macOS/Linux lanes passed. Focused results included 54 agent-filter tests with one ignored and 111 plugin tests.

The full Blacksmith Testbox core suite was not green. Remaining failures included older or unrelated assumptions around direct hook projection versus list roster, startup plugin projection restore, live cwd behavior, and topology registries. Do not describe the entire suite as passing without re-running and separating these failures.

## Freestyle snapshot status

Snapshot created/restored:

`sh-0b044c977c1f4b62b437b7b44df79813`

This is a validated daemon base only. It does **not** contain the exact PR Linux daemon and reference-plugin binaries. The private push path disconnected, and the default image daemon uses a different artifact contract. The feature-baked snapshot is therefore still incomplete.

Earlier live Cloud checks created and removed test VMs. A hook resource was observed with:

- `state: working`
- `source: hook`
- revision `6`

That check did not prove the complete detector-to-journal-to-sidebar-icon path. No owned Blacksmith Testbox should be assumed to still be running.

## Fleet Mac build

This is the correctly named exact-head build:

- Job: `700a0bd3734b9fa40c241f58`
- Tag: `pr-13299-herdr-agent-icons-v1`
- SHA: `829c0615e62b9a6427cd66df8dffe6f5276a324b`
- Worker: `cmuxs-Mac-mini-3.local`
- Total: 727.65 seconds
- Compile phase: 697.73 seconds
- Artifact digest: `sha256:14e93ed98deaf27f2268a4943226f6dd4ce69400fbc34f10c492cab5de5921ac`
- Submission receipt:
  `artifacts/fleet/pr-13299-herdr-agent-icons-v1/submission.json`
- Terminal receipt:
  `artifacts/fleet/pr-13299-herdr-agent-icons-v1/terminal.json`
- Publication receipt:
  `artifacts/fleet/pr-13299-herdr-agent-icons-v1/publication.json`

The archive was downloaded and verified to contain:

`cmux DEV pr-13299-herdr-agent-icons-v1.app`

Local HQ Tag Opener link:

http://127.0.0.1:17320/pr-13299-herdr-agent-icons-v1

This is a Mac artifact only. It does not include the Freestyle snapshot or prove Linux daemon/plugin deployment, cloud API behavior, or live icon rendering.

Use the current build-fleet contract. Always submit an exact pushed SHA with a fresh descriptive `--tag`, save separate receipts, wait on the same job ID after disconnects, publish through HQ, and verify both the returned tag and top-level app name. Do not use a generic tag or resubmit after a wait timeout.

## Documentation follow-up

The shared HQ instructions were missing the mandatory descriptive tag and verified-link handoff requirements. Documentation PR:

https://github.com/manaflow-ai/cmuxterm-hq/pull/536

It updates the symlinked `AGENTS.md` through `CLAUDE.md` and requires:

- exact SHA plus descriptive iteration tag
- separate submission and terminal receipts
- same-job retry after observer disconnect or timeout
- HQ publication and tag/app identity verification
- explicit distinction between compile artifacts and runtime E2E

## Remaining work

1. Provision a fresh Freestyle environment from the validated base and bake the exact PR Linux daemon and reference-plugin binaries into the image using the supported private push/artifact contract.
2. Restore the feature-baked snapshot and verify the exact daemon and plugin versions, not merely that `/usr/local/bin/cmux-tui` exists.
3. Run live E2E from terminal activity through plugin detection, journal event/fold, durable resource `extra.agent`, Cloud TUI payload, and sidebar icon. Exercise at least Claude, Codex, OpenCode, and representative additional providers.
4. Verify local tab icons from the same structured provider identity path, including provider changes and disappearance/cleanup.
5. Re-run focused plugin, journal, Swift icon, and Cloud sidebar tests on the final head.
6. Audit `ATTRIBUTIONS.md` and generated manifest metadata for stale Herdr revisions or counts.
7. Update PR #13299 with only verified snapshot and E2E evidence. Do not claim full-suite green until the known failures are resolved or explicitly isolated.
8. Do not merge without a direct user merge directive.

## Operational constraints

- Do not build cmux locally on this Mac. Use the controller fleet for Mac builds.
- Do not run local cargo, rustc, or zig for cmux-tui. Use the Blacksmith Testbox workflow for Linux/Rust/Zig work.
- Do not use maclease, reload-cloud, direct SSH builds, or retired fleet flows.
- Do not alter credentials, Tailscale, SSH keys, or ACLs.
- Read the worktree's `AGENTS.md` and the current build-fleet skill before continuing.
- The current worktree is shared. Coordinate with other agents and do not revert their edits.

