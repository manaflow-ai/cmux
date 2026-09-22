# VM startup and Herdr integration

Goal: finish the whole change, fresh Freestyle size snapshots, exact-source Mac
and Linux builds, full end-to-end validation, timings, and ready-to-merge PR.
Do not merge without a direct merge directive. Existing PR:
https://github.com/manaflow-ai/cmux/pull/13299 (lawrencecchen).

## Required final behavior

- New VM allocation has one Freestyle create POST; VPC and TLS rules are inline.
- No create-time resize, guest exec, file upload, or attach-time healing/install.
- Resolve account VPC alongside VM row/billing/token preparation; join before create.
- Bake all CLIs, browser integration, agent hooks, resource reporter and exact
  Herdr detector/plugin binaries into the new snapshot.
- Warm cmux-tui and the first workspace/terminal before memory snapshot, settle
  for 30 seconds, and verify two independent clones. Identity changes must not
  discard the warmed terminal. Prior claims that keeping a warm terminal was
  categorically impossible were not proven; investigate listener identity vs PTY
  process ownership and implement a clone-safe boundary.
- Prompt slug acquisition runs concurrently with startup; never gate usable
  terminal access on potentially slow edge propagation. A refresh must preserve
  input, foreground applications and history after user interaction. A pair of
  clear-history/Control-C RPCs is NOT an atomic input fence and is insufficient.
- New-machine open uses the initial-terminal receipt rather than refreshing the
  entire catalog or creating a duplicate first terminal. Reopen uses real state.
  The app still has to link the new machine once: `cmux vm open` reads
  `surface.catalog` with `ensure_linked: true` (one connect plus one graph read,
  free for a machine that is already linked). A plain cached read has no graph
  for a just-created VM and fails with "sessions are unavailable" (seen on tag
  pr-13299-vm-startup-v4, VM vm-3d661f4b2bbf4aef85f42878cd7b5efc). Do not drop it.
- Freestyle create/restore/resume/attach do no guest work; see the NO-WORK
  INVARIANT in web/services/vms/drivers/freestyle.ts. New guest work is baked.
- Consolidate VM edge credential to one x-cmux-authorization Bearer header;
  signed VM claims retain validation, expiry, ownership and revocation semantics.
- Old-image create/attach healing is intentionally retired, not silently retained.
- Preserve explicit user resize/exec operations and production tenant isolation.
- Preserve and complete all AGENT_HANDOFF.md requirements, including detector ->
  journal -> durable extra.agent -> local/Cloud icons, provider changes/cleanup,
  attribution audit and final exact-head hosted full verification.
- Report measured create, connect, prompt, agent-ready and per-stage timings with
  sample counts and environment; historical percentiles from different span
  populations are not additive or an end-to-end measurement.

## Current evidence (2026-09-21)

Implementation in progress, no commits/push yet beyond inherited 829c0615e62.
Dependencies installed with bun install --frozen-lockfile in web.
Initial provider tests: 39 pass, 22 fail (mostly old install/repair expectations).
Changed TS files lint clean. Typecheck initially unavailable until deps installed;
full result must be captured, not inferred from filtering for changed filenames.
No new snapshot or live E2E produced. Existing handoff snapshot lacks exact plugin.

## Remaining gates

- Complete implementation and behavioral tests, including snapshot contract proof
  rather than marking arbitrary create/restore images snapshot-v2.
- Validate async prompt worker, first-terminal ownership and shell redraw against
  live shell/ble.sh with input racing updates. Do not synthesize Control-C into
  a user's shell.
- Bake exact Linux binaries; verify digest and plugin manifests in restored image.
- Derive and validate all size snapshots, then update the image manifest.
- Full web checks and targeted DB behavior; hosted Rust full checks plus Mac build.
- Tagged backend preflight; isolated real app New Machine, prompt input, agents
  and provider icon E2E; cleanup only owned test resources.
- Fresh Axiom and benchmark evidence, PR bot feedback and mergeability audit.
