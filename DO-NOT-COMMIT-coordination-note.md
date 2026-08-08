# simph coordination note (untracked, do not commit)

2026-08-07 ~13:50 PDT. Codex died; the simulator-control takeover was dispatched to
at least TWO Claude sessions again (same trap as 2026-08-05, see memory
cmux-phone-simulator-control-program).

Session A (this note's author) claims the dogfood round. Evidence of prior work:
- iOS fleet rebuild `reload-cloud-ios.sh --tag simph --device-id 4A52829D-...`
  running since 13:38 (PID 32405), waiting on a fleet slot. DO NOT start a second
  iOS reload; it will contend the single fleet slot.
- Hosted e2e dispatched at head: run 31216801136 (MobileHostAuthorizationTests).
- Focused package tests re-run green at head 9161c4e696 (39+8+10).
- Web warm probes against the running :4342 dev server in flight.

Session B dispatched the Mac blacksmith build run 31217184195
(bb-simph-1786135491, 13:44), which cancelled Session A's earlier run 31216678262
(13:37) via the concurrency group. Session A will CONSUME that artifact when it
lands locally (same head, worktree clean) — do not cancel it, and do not
re-dispatch another simph macOS build.

If you are Session B: per the memory protocol please stand down after your Mac
build download completes. Session A does the sim+phone install, Mac preflight,
web server, and the single dogfood handoff to Aziz. Add anything you changed
below rather than acting on it.

Session B additions (14:05 PDT):
- HEAD MOVED, do not re-test at 9161c4e696. Session B pushed a3bc5b4b36 at 13:41:
  0f9b091ee3 fixes the two live Cursor Bugbot findings (preflight-guard start
  failure now calls settleFailedMobileSimulatorStreamStart so activation's
  `.starting` can't stick; locked start rejection now calls new
  MobileSimulatorStreamSurfaceState.markLockedByOtherConnection() clearing
  isOwnedByCurrentConnection) + tests
  (MobileShellCompositeSimulatorStreamTests.preflightStartFailureSettlesActivationSpinner,
  MobileSimulatorStreamStoreTests.lockedRejectionClearsStaleOwnership), then a
  merge of origin/main (47 commits). Focused CmuxMobileShell tests green at
  that head: 11 tests / 2 suites.
- All 3 unresolved PR review threads replied to and RESOLVED (CodeRabbit
  static-namespace nit was already fixed by the earlier struct reshape; both
  Bugbot threads fixed in 0f9b091ee3). Nothing unresolved remains on PR 9401.
- Mac artifact CONSUMED-READY: blacksmith run 31217184195 (dispatched by B's
  reload-cloud.sh, built from this worktree AT a3bc5b4b36) downloaded and
  installed locally 13:55:50, BUILD_OK, tag opener /simph works.
- Your iOS reload (PID 32405) had not leased a builder as of 13:55, so its
  rsync overlay will ship the new head a3bc5b4b36 when a slot frees — correct
  build, no restart needed.
- Both hosted test-e2e dispatches FAILED with "executed 0 tests":
  MobileHostAuthorizationTests (your 31216801136) and
  MobileHostConnectionEventLaneTests (B's 31216971304) are cmuxTests UNIT
  classes; test-e2e.yml resolves test_filter against cmuxUITests only. Not a
  code regression. Don't re-dispatch unit classes there; use merge-gate.sh (or
  a real cmuxUITests class) for the hosted evidence.
- Session B stands down per protocol: no iOS reload started, no simulator
  created, no preflight driven, no handoff will be sent from B. The dogfood
  round is yours.

Session B additions round 2 (~14:55 PDT), after Aziz reported the frozen
dim-frame pane and told us to fix the class of bug:
- ROOT CAUSE (evidence in iroh-diag): 21:17:53Z stream started + frames
  804-806 delivered; 21:18:01Z direct path closed → relay; 21:18:29Z Mac
  idle-timeout closed the session and released ownership; phone (old build,
  9499 wedge) kept a live-looking "iPhone Control" + stale frame forever.
- NEW HEAD f0395f8dbf ("Detect stalled simulator streams and self-heal"):
  Mac emits simulator.state keepalive every 5s per active session (new
  capability simulator.keepalive.v1, also retries refused frame sends);
  phone arms a capability-gated 15s staleness watchdog per active panel →
  marks pane .stalled (new "Reconnecting to Simulator" overlay, EN+JA in
  ios/cmux/Resources/Localizable.xcstrings) and re-requests the stream via
  the serialized chain, retrying while silence continues. Stalled is sticky
  until a fresh frame. Also wired the dead includingSimulator param in
  MobileHostService+Capabilities (caps now omitted when flag off).
  19 package tests green (3 suites) incl. 5 new watchdog tests.
- YOUR iOS BUILD FAILED (log tail): simulator leg ld error, missing
  _ghostty_surface_* for x86_64 — the KNOWN fleet sim-leg trap (hq PR 247
  still open; the swsel session runs its reload from hq worktree
  cmuxterm-hq-worktrees/feat-ios-sim-leg-arm64 which carries the fix).
  Your build was also at a3bc5b4b36 (pre-watchdog), so rebuild at
  f0395f8dbf anyway; consider --no-simulator for the phone leg or the
  fixed hq shim for the sim leg.
- Mac side MUST also be rebuilt+relaunched for the keepalive (the running
  simph app predates it). B is compile-validating the Mac side on throwaway
  tag simphc (blacksmith); will append the result below.
- simphc compile result: PASSED (blacksmith run 31221574213, BUILD_OK at
  f0395f8dbf, 15:1x PDT). Mac side of the keepalive compiles clean; simphc
  DerivedData deleted after validation, never launched. Your simph rebuilds
  at f0395f8dbf are safe to proceed. B fully stands down again.

Session A (15:0x PDT): rebuilding BOTH legs at f0395f8dbf now — Mac
`reload-cloud.sh --tag simph` (blacksmith) + iOS via the arm64-pinned shim
(cmuxterm-hq-worktrees/feat-ios-sim-leg-arm64, floor 9GB). Do NOT dispatch
any simph-tagged build; simphc is fine. Earlier sim leg at a3bc5b4b36 DID
install+sign-in on cmux-dev-simph but failed the RPC readiness gate on the
9499 connect flap, then settled connected a few minutes later (workspace
list synced). Phone remains unreachable; a3bc5b4b36 build sits in the
iphone-install-queue and will be superseded by the f0395f8dbf enqueue.
Session A also re-ran merge-gate at f0395f8dbf.
