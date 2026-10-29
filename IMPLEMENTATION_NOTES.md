## 2026-10-15 native Home workspace correction

- Fleet v12 at `4bea721bcd1` compiled and launched with the native Home group
  above the local workspace row. Archive digest and bundle tag were verified.
  Its first launch exposed a `chief.open` subscriber race: the socket replied
  before the native selection was applied. The socket now calls the shared
  `ChiefHomeNavigation` action on the main actor before replying. The live
  regression also explicitly returns to a local workspace before opening Home;
  ten warm v12 round trips passed, while the initial cold open failed.
- V13 exposed the second half of that regression: the read-side socket mirror
  could still return the pre-open selection after the main-actor action.
  `chief.open` now schedules and awaits the existing snapshot publication
  before returning, and reports `opened: false` when Chief is disabled.
  The same cold-start regression failed on v13 and passed on v14 immediately
  after launch, without delays or polling.
- Fleet v14 (`5915e9188df741d60858a210`) built product sources at
  `5db3745214a451ca35deef2f53ac9464580950b7`, published as
  `http://127.0.0.1:17320/issue-21063-chief-home-v14`, and launched. Verified
  archive digest `0e8dd051fe8b8719290a4c7ed223495470d2805af143549af6c8953d4ac1540f`,
  exact tag, bundle id and embedded commit. Native Home and Settings captures
  are in `.chief-work/shots/native-home/`; the permission bypass is off.
  Full hosted verification remains pending; app compilation and the live
  socket regression do not establish app-host unit-test or tour coverage.
- Hosted run `38842982269` completed with seven test-target diagnostics in
  `ChiefListAndSettingsCopyTests`: four unresolved `ConversationID` uses and
  three initializers missing the newly required permission flag. The test
  now imports `CmuxHomeCore` and supplies explicit safe permission defaults.
  This follow-up changes test code only; the v14 app artifact contains the
  same product sources. The light tour's first attempt was cancelled before
  execution and provides no light-mode or AX evidence.
- Read-only review found no healthy-state drag/focus blocker. A manually
  malformed persisted Home group (a canonical anchor assigned to another
  group) still needs a dedicated restore-repair path; normal grouping actions
  prevent that state. This remains a resilience gap, not verified behavior.
- The rejected floating conversation picker is removed. Home uses cmux's native
  workspace group/header with the house icon, pinned above local workspaces.
  Each additional Chief is an ordinary member workspace; expanding Home pushes
  local rows down within the same list and scrolling surface. Both the AppKit
  and SwiftUI sidebar use their existing group/row implementations. Reference:
  `cmux-design-references/topics/sidebar.md`, with the shipping native workspace
  group rows as the implementation reference.
- Home is now a real workspace layout, so browser and terminal splits use the
  existing pane machinery. Shortcut, menu, palette and `chief open` resolve its
  native anchor through one action path. New Conversation and Home's plus open
  a native Chief workspace. Restored conversations preserve selection, manual
  renames and the existing local conversation archive.
- Regression `tests_v2/test_chief_native_home.py` was committed before the fix.
  With `CMUX_SOCKET_PATH=/tmp/cmux-debug-issue-21063-chief-home-v9.sock`, it fails
  at `chief.open must select a native Home workspace, not an overlay`.
  The same command will run against the replacement tagged artifact.
- Canonical Home identity is persisted with the Chief panel snapshot. The
  canonical tab is pinned and shared close/force-close paths refuse removal.
  Cross-container drags resolve to the existing conversation-copy router, so
  duplicates get fresh identities while the original remains in Home. This
  avoids returning a copied pane's id through an API that promises a move.
- The light/dark scripted tours now open Home through `chief.open`, so their
  navigation targets the native workspace instead of the removed overlay row.
  The canonical tab also enters the workspace's pinned-panel registry so its
  session snapshot and restored close affordance retain the protection.
- The dangerous permission bypass remains opt-in and off by default. No new UI
  copy was needed for this change. `localize-changes --base dea8e6e31f8` and
  strict catalog validation pass all 11 catalogs/nine locales. Static affected
  verification and Swift parsing pass; native build/runtime evidence is pending.

## 2026-10-15 preview launch and localization repair

- Exact-head fleet job `f98592121ff41df8f60fc473` built `0a3eac2b25e`
  successfully as `issue-21063-chief-home-v9`. Published through HQ, verified
  the archive and installed bundle identity, launched the tagged app, and
  confirmed its socket responds. Opened Chief Settings and verified the
  accessible `ChiefSettingsDangerousPermissions` checkbox is visible and off.
  The AX inspection verified the toggle. The subsequent screenshot
  `.chief-work/shots/chief-home-v9-permissions.png` captured workspace mode
  after navigation changed; it is not screenshot evidence of Settings.
  The user's stable cmux was not changed.
- Reproduced localization parity failure (738 diagnostics), then removed 90
  unused English-only app-catalog duplicates whose strings are resolved from
  translated package catalogs with `bundle: .module`. No app/CLI source uses
  those keys. Added the three missing memory-edit translations for all eight
  non-English required locales and updated translated dispatch help to match
  the opt-in permission bypass. The same localization command now passes all
  11 catalogs and nine required locales; affected verification passes 4/4.
- Updated the existing PR guide to distinguish earlier package-test evidence
  from exact-head compilation, and to state the remaining editable Home
  workspace gap. Native test execution and final CI still need completion.

## 2026-10-15 tagged build compile fix

- Read every unique compiler diagnostic from the fleet logs: corrected the
  argument order in both detached Dock transfers and Chief Dock creation.
  Extracted the Home overlay from the sidebar's large SwiftUI body so its
  generic type is checked independently, and replaced its unsupported combined
  maximum-width/fixed-height frame calls with valid bounded-height frames.
  The permission bypass remains exposed
  in Chief Settings and Automation settings, off by default, and feeds both
  harnesses when a new turn starts.

- The first exact-head fleet build caught two Xcode-only issues in the Home
  conversation host: it now imports `CmuxFoundation` for `CmuxAccentColor` and
  explicitly implements the unavailable required `NSHostingView` initializer.
  The follow-up build also caught the missing public `onOpenCloudDesktop` host
  forwarding property, the missing `CmuxSettings` import, and an initializer
  label ordering mismatch. The next build exposed the new Chief drag source in
  three existing cloud ownership switches; those switches now classify Chief
  as a local source and the corrected head is ready for another fleet build.
  The subsequent compile also required the SwiftUI binding to be explicit and
  a DEBUG drag log interpolation to be split into a local value; both are now
  fixed before the next tagged submission. Fleet's SwiftUI type checker still
  rejected the interpolation passed through its autoclosure, so the debug line
  now passes a prebuilt `String` value. The resulting build then surfaced the
  adjacent checklist style expression at the same large `ContentView` body;
  that value is now also captured before branching.

## 2026-10-15 Chief Home pane drag

- The pinned Chief Home row now carries a live Bonsplit transfer lease for the
  conversation Home is showing. Dropping it on a workspace or right Dock pane
  uses the existing pane-transfer router, creates or focuses the matching
  `ChiefPanel`, supports center and edge split zones, and leaves canonical Home
  mounted. The conversation id stays process-local; stale pasteboard data cannot
  create a pane. Added resolver and create/reuse coverage in
  `ChiefPanelSessionTests`.

## 2026-10-15 persistent Home disclosure

- Home now has an explicit disclosure affordance in the left sidebar. When it
  is collapsed, workspace rows remain the primary list; expanding Home reveals
  a compact sequential stack of Chief conversations in that same sidebar
  surface. Selecting a disclosed conversation activates Home and keeps the
  thread mounted.
- Each disclosed conversation is a live pane-transfer source, so it can be
  dragged into a workspace split or the right Dock and becomes a duplicate
  `ChiefPanel`. The canonical Home row and its default conversation remain
  protected from delete actions; duplicates continue through the ordinary pane
  close path.
- The compact stack uses the same Home projection used by MessagesLab, so
  unread dots, human previews and Chief selection stay aligned with the full
  Home list. New disclosure copy is localized in all nine macOS catalogs.

## 2026-10-15 interaction follow-up

- Added a red-before-green cloud regression for a failed `vm wait`: the provisioning row retains its machine name while showing the failure state, so result copy never falls back to a raw VM id.

- Fixed the shared Home sidebar action policy so the required default Chief conversation no longer advertises a Delete action that the host must refuse; ordinary conversations keep Delete through the same swipe/context-menu path.
- Made the compact Settings memory rows keep their Forget affordance visible and refresh immediately after the single `ChiefMemoryStore.forget` mutation, so the x button reliably removes a note without depending on hover or watcher timing.
- Re-ran the focused Chief cloud suite (7 tests) and the MessagesLab Chief list/cloud suites (14 tests); both pass. Affected static verification, test wiring, and localization catalog checks pass.

## 2026-10-15 current verification and dogfood

- 2026-10-15 continuation: the dangerous permission bypass is now exposed in
  General Settings and Chief Settings, persisted at `chief.dangerouslySkipPermissions`,
  and guarded by a localized confirmation; it remains off by default. Chief's
  cloud prompt now keeps remote launches safe by default, teaches `vm open
  <machine>:desktop` plus `cua-driver` verification/action loops, and offers a
  gentle Pro upgrade only when Cloud reports a real availability or plan limit.
  The Home sidebar's built-in swipe/context delete action now hides a
  conversation durably on this device and returns to the default Chief thread
  when the selected conversation is removed. A focused projection test covers
  that transition. `verify-local.py --affected`, localization parity, test
  wiring, app-source wiring, feature-flag policy, and Swift syntax all pass;
  the dedicated package host was unavailable in this session, so hosted CI is
  the native compilation/test proof.

- 2026-10-15 permission safety follow-up: Chief now persists
  `chief.dangerouslySkipPermissions` (off by default) in the catalog, cmux.json
  schema, general Settings card, and the in-Home Chief Settings panel. Turning
  it on requires a localized warning confirmation; it applies from the next
  turn. Codex uses `approvalPolicy=untrusted` and `workspace-write` by default,
  switching to `never` and `danger-full-access` only when explicitly enabled;
  Claude switches to `bypassPermissions` only in that same opt-in mode. The
  dispatch CLI no longer starts Codex with `--yolo` by default, and the prompt
  tells Chief to add it only for an explicit opt-in. Focused and full CmuxChief
  tests pass (181 tests/25 suites); localization and embedded schema checks pass.

- 2026-10-15 final polish: pushed `599160eff44`, which suppresses the duplicate
  completed `cmux chief memory add` row when the same assistant message also
  contains acknowledgement prose. The prose bubble and dedicated memory
  receipt remain visible. CmuxChief passes 179 tests/25 suites and the focused
  MessagesLab Chief slice passes 58 tests/6 suites. A fresh exact-head fleet
  build is submitted as `issue-21063-chief-final-v7`; the exact-head PR wait is
  running for this SHA.

- The light tour build `38823561565` proved the prior settings scroll-cue code
  did not compile under Xcode 26 (`NSImage` was already optional and had an
  unnecessary optional chain). Removed that chain in `7f4b331e00d`; local
  affected verification passes, and the exact-head hosted wait is green for
  the current guard set. A replacement fleet build is queued as
  `issue-21063-chief-final-v8`.

- 2026-10-15 mixed memory-save projection: when an assistant message contains
  acknowledgement prose alongside a completed `cmux chief memory add` work
  part, Home now keeps the prose bubble and suppresses the duplicate command
  row. The dedicated memory receipt remains the confirmation. Added a focused
  `ChiefNoticeRowsTests` regression; the 17-test suite, affected verification,
  and Swift syntax checks pass.

- The previous pushed head `49c89dddc3a7cc21241d6f9bddbd4c8de1cb4049` was superseded by `599160eff443cfc44c666a37e33d2e32e8949b16`; local CmuxChief package tests pass 179 tests/25 suites and focused MessagesLab Chief tests pass 58 tests/6 suites.
- The prior fleet submission `7f40a973977a6a0f5afabd20` failed during its build phase. The replacement exact-head submission uses tag `issue-21063-chief-final-v7`; publish only after its receipt verifies the requested tag and app name.
- Light dogfood tour `chief-home-tour-light.json` dispatched against the exact head with frames/AX capture; dark tour follows once the light run completes.
- Cloud round-two behavior remains covered by the current prompt and tests: answered questions collapse, names are shown, failures override Allowed, vm exec Always Allow is machine-scoped, `/home/cmux` is used without home probing, HQ checkout pushes are refused, sign-in is checked before launch with Device Code guidance, and result cards offer Stop Machine.

## 2026-10-15 unread projection follow-up

- The Home list now suppresses the selected conversation's stale unread count as soon as its transcript is mounted. The owner read cursor still advances through the normal store operation; the projection no longer flashes a dot while that async update is in flight. Added a pure `ChiefHomeView.unreadCount` test covering selected, visible, and manually marked rows. Affected verification and Swift syntax checks pass.

## 2026-10-15 latest continuation

- Pushed `f0c3ba32277`, combining the cloud round-two implementation already on the branch with the deferred transcript geometry callback, Chief settings/Home affordances, and the Always Allow accessibility label.
- Audited hosted run `38797338970` for stale `d3f39f0`: Chief failed only on the pre-resource-layout localization assertion; HomeCore ended with the runner's signal 11 after the attachment fixture; app-host failures were LaunchServices setup and the unchanged `SidebarLazyLayoutScaleTests` ratchet. Current HEAD repairs the package failures and has no app-host wiring change.
- Current local evidence: CmuxChief 178 tests/25 suites, CmuxHomeCore 138 tests/24 suites, focused MessagesLab Chief 57 tests; `verify-local.py --affected`, test-wiring, and localization catalog validation pass. Full MessagesLab motion golden remains host-OS-sensitive on macOS 15.
- Hosted exact-head wait is running for `f0c3ba32277`. The PR body now has the fleet dogfood guide, capabilities, cloud re-test evidence, validation and known gaps.
- Cloud cleanup remains complete: `chief-dogfood-1` is absent and no VM created by this task remains; unrelated pre-existing VMs were not touched.
- Local follow-up `0d9854e7a61` clears a persisted Chief effort when the selected model is
  unknown or does not advertise that level, so the next turn stays on the model's default;
  CmuxChief remains green at 179 tests in 25 suites and affected verification passes.

# Chief for cmux classic: implementation notes

Status board for the overnight "cmux instinct" goal. Supervisor: read this file.

## Status (newest first)

- 2026-10-15 transcript geometry follow-up: Chief's header overlay now refreshes
  after off-main exact row remeasurement and long-text fold/height commits, the
  two geometry paths that can change row positions after the normal engine
  callback. This keeps the header band over transcript content during automatic
  growth and width/long-text reflow. The implementation follows
  `cmux-design-references/topics/transcript.md`'s fixed header treatment and
  `topics/sidebar.md`'s readable conversation surface. Focused MessagesLab
  Chief tests remain green (57 tests).

- 2026-10-15 cloud round-two cleanup: re-tested the current dev-backend machine
  `chief-dogfood-1` (`vm-6c45bc82bdf04d83861d1d9925d66064`) from the tagged
  Chief build. `vm tree --json` resolved its display name and guest paths;
  one bounded `vm exec` preflight used `HOME=/home/cmux` and reported Codex and
  Claude as not signed in, so no agent was launched. The tagged app's Chief
  transcript contained the Device Code guidance and a failed/needs-sign-in
  outcome from the earlier real run. I paused and removed that VM, then checked
  `vm ls --json`: the task-created inventory is empty. The originally reported
  `vm-794a4009e0b04396a17dae037acb59a8` was already absent.

- 2026-10-15 CI log audit: run `38797338970` was for stale `d3f39f0bc0d`.
  `swift-package-tests` failed at the old SwiftPM `ja.lproj` lookup and the
  pre-`9d9ff092493` attachment fixture, plus a `CmuxHomeCore` signal 11; the
  current head contains the bundle-layout lookup and decodable-image fixture
  repairs. The four app-host failures were LaunchServices `childPID > 0`,
  `BrowserDeveloperToolsVisibilityPersistenceTests`, and the pre-existing
  `SidebarLazyLayoutScaleTests` pointer ratchet; no Chief test target wiring
  caused them. An exact-head wait is running for `94cafcdb983`.

- 2026-10-15 settings polish: `94cafcdb983` gives the Activity “Show in Finder” control an accurate accessibility identifier (and removes the duplicate path assignment). `python3 scripts/verify-local.py --affected` passes; the exact-head CI wait is running for this SHA. The first retry of the exact fleet build timed out during dev-backend provisioning before submission; a second submission is in progress as tag `issue-21063-chief-settings-v4`. The PR body now contains the current SHA, fleet guide, capabilities and known gaps.

- 2026-10-15 memory-sheet polish: `44996fbf903` makes notes in the full Chief
  Memory sheet visibly editable and deletable. Editing preserves the note's id,
  source and timestamp while applying the same size and secret validation as a
  new fact. The CmuxChief package suite passes all 178 tests locally; the commit
  is pushed and the exact-head PR wait is running.

- 2026-10-15 warning-budget follow-up: removed Swift 6 warning sources from the
  newly vendored Home packages (Foundation imports that were not part of a
  public API, the AppKit font cache's locked Sendable boundary, unused vendor
  locals/captures, and the motion golden's unhandled-file scan). The focused
  MessagesLab Chief suite passes without compiler warnings; `verify-local.py
  --affected` is green. This local repair is ready to push with the next CI
  wait.

- 2026-10-15 CI follow-up: inspected run 38797338970. Its package lane executed the new Chief suite and failed only in the pre-9d9 attachment fixture and the pre-5e96e25 localization lookup; current focused CmuxChief and CmuxHomeCore tests pass. App-host 1/3 are baseline BrowserDeveloperToolsVisibilityPersistenceTests and SidebarLazyLayoutScaleTests ratchets; 2/4 abort in Xcode LaunchServices startup (`childPID > 0`) before any test. Commit `5e96e25a441` makes the SwiftPM localization assertion locate the catalog in both flat and Contents/Resources layouts and removes repeated “Ran” from expanded child tool rows, with a focused MessagesLab test.

- 2026-10-15 CI follow-up: run 38797338970 was for the pre-`8e2a161d748` head, so its Chief localization failure is stale; the SwiftPM bundle lookup passes on the current head. The intentional sidebar interpreter crash-sentinel output is also present on `origin/main` and its recovery test passes there. App-host shards 1 and 3 failed unrelated pre-existing browser/sidebar ratchets (`BrowserDeveloperToolsVisibilityPersistenceTests` and `SidebarLazyLayoutScaleTests`) after their other tests passed; this PR does not change those test files. Hardened the HomeCore attachment fixture in `9d9ff092493` to require ImageIO to create a decodable frame before testing an advertised image writer; the Photoshop writer otherwise reports a container that `prepare` correctly rejects. Focused test, affected verification, localization audit, and test-wiring check pass. Pushed the repair and started the exact-SHA `glaeda-gh wait` for `9d9ff092493`.

- 2026-10-15 handoff continuation: pushed `114d00f95e0` with the package-test
  and warning-budget repairs. The required PR wait reports 68 passed, 0
  failed, with `swift-package-tests` and macOS compile admission still pending
  on that SHA. Local follow-up `98e470bb4b8` refreshes the Chief header fade
  after the transcript commits its final geometry and suppresses unread dots for
  the visible/key conversation; it is intentionally not pushed until the
  pending package run completes. Focused package tests pass locally, including
  all Chief cloud flow/row suites (23 tests) and the SwiftPM localization and
  bottom-inset regressions. A live preflight on the dev backend confirmed the
  original `chief-dogfood-1` VM has incomplete agent authentication; the paused
  task VM was removed afterward, and the dev backend now has no VMs created by
  this task. The existing PR body now includes fleet build, dogfood, capability,
  evidence, and known-gap guidance.

- Real cloud run (fleet build chief-cloud-v1, remote dev backend, real Claude
  brain): question card -> vm new (approved) -> machine chief-dogfood-1
  (vm-794a4009e0b04396a17dae037acb59a8, 4 GB, ready ~76 s) -> workspace
  ws_962f7662bf72765703c4cf040502b058 / term_bf403e6e12735dbabcb7869a0d5c50e9
  -> codex --yolo launched -> stopped at Codex's own ChatGPT sign-in. A later
  bounded preflight confirmed the same incomplete VM agent authentication, then
  the named test VM was destroyed; no task-created VM remains. Details:
  .chief-work/cloud-run.md, shots/cloud/.
- Admission repair: run `38793803400` completed with the expected
  `CLIVMTransferTests.swift` target error (`CMUXCLI` is owned by the separate
  CLI target). Removed the two invalid direct helper assertions in
  `d3f39f0bc0d`; the test still verifies the large-push refusal through the
  bundled CLI and mock socket. `verify-local.py --affected` is green.
- CI: guards/web/lint are green. Run 38793803400 has 68 passed and 0 failed;
  its package lane passed but macOS admission failed only on those invalid
  `CMUXCLI` references. Pushed the repair as `d3f39f0bc0d`; the required
  `glaeda-gh wait pr manaflow-ai/cmux#21063` completed with 20 passed and 0
  failed while the new CI workflow continues routing its macOS lanes.

- **PR: https://github.com/manaflow-ai/cmux/pull/21063 (draft, the one PR).**
  v3c green (fleet job 76d8d0d19dcfa9310f5b5294, tag chief-wip-v3c). Running
  locally (background) at /tmp/chief-v3c/app with CMUX_CHIEF_BRAIN=scripted,
  socket /tmp/cmux-debug-chief-wip-v3c.sock; CLI
  "/tmp/chief-v3c/app/cmux DEV chief-wip-v3c.app/Contents/Resources/bin/cmux".
  Shots: .chief-work/shots/v3c-firstrun.png, v3c-approval.png. Ready for the
  independent evaluator. In flight: correctness review subagent; Home nav back
  affordance + previews + first-run balance; approval card polish (accent
  Allow, always-allow chevron, caption, waiting line, Markdown-free previews).
  CI tour 1 running on SHA in .chief-work/tour1.sha. Note: v3c predates the
  cloud question/result cards and the catalog cleanup (in the next build).

- Evaluator v2 = 4.8/10 (/Users/cmux/manaflow/cmuxterm-hq/.dispatch-prompts/chief-eval-v2.md).
  Fixers on every P0/P1: approval card + work rows (P0-1/2, P1-7), sidebar
  becomes the conversation list on Home / single selection / read / dot /
  ChiefAvatar.png / quiet row / one material (P0-3/4, P1-1/2/8), first run per
  cmux-next + 3 suggestion chips (P1-3), settings parity (P1-4), memory UX
  (P1-5), cloud flow cards via structured question/result blocks (P1-6),
  working status row + motion proof (P2). Next: v3 build, CI tours, re-eval.

- Fleet build v2 (job 0d7b20807c1512f84be6fab0) compiles. Local tagged app
  (background, socket-driven): Home row, Messages list, header pill, first-run
  chips, composer render; a real Claude turn ran `cmux tree` (end to end works).
  Defects found -> fixers running: approvals/tool calls render as plain
  bubbles (custom rows + Allow/Deny card), auto-allow too strict (pipes),
  workspace row still highlighted on Home, titlebar shows "~", avatar style,
  chief.enabled band, first focus, unread while visible.
- GUI dogfood route: cloud-mac lease works but this laptop is denied by tailnet
  ACL to tag:cmux-loader (policy change -> not ours to make; documented in
  .chief-work/cloud-mac.md). Using CI dogfood tours (XCUITest real clicks,
  screenshots, AX trees, PR media GIFs) with a DEBUG scripted brain
  (CMUX_CHIEF_BRAIN=scripted) + local tagged app with the real brain captured
  via `cmux shot`/`cmux record` (real app pixels).

- Parity catalogue done: chief-parity.md (233 items, 22 areas, source-cited at
  feat-cmux-next e15a0fb). The published nightly-next (2026-10-04,
  1.0.0-nightly.3865928435701) predates the MessagesLab UI, so the live
  reference for the transcript is the vendored code itself (byte-identical in
  classic => transcript parity by construction); hosting parts (header pill,
  Chief settings 280pt panel, first run, sidebar) are compared against source.
  cmux-cua is unavailable on this Mac ("Computer Use onboarding is still in
  progress"; no AX/Screen Recording grant), so dogfood drives the tagged app
  through its socket (`cmux chief send/open`, DEV debug hooks) and captures
  with `cmux shot` / `cmux record` (permission-free, cmux windows only).

- Build phase fanned out (8 agents): CmuxChief store (owner + HomeSource),
  brain drivers (Claude stream-json long-lived, Codex app-server), prompt +
  memory + `cmux chief memory` CLI, Xcode wiring + Home mode + Home row +
  `.chief` panel type, Chief Home UI + ChiefService, settings keys `chief.*` +
  "Open Chief" shortcut/palette, parity catalogue (nightly-next). Build host
  (nx-remote) is down (REPAIR row 105; mini-6 under disk floor) -> compile via
  fleet `cmux-ci build cmux --working-tree` once wiring lands.
- Brain decision refined (report-brain): long-lived `claude -p` stream-json
  per conversation (permission-prompt-tool stdio -> approval cards; auto-allow
  `cmux …` and read-only tools), Codex via `codex app-server` (exec --json has
  no deltas). Memory phase 1: person.md / instructions.md / memory.jsonl in
  the Chief home, written via `cmux chief memory add` (single format, flock).

- 2026-10-15: Recon fanned out (UI packages port, nightly-next parity catalogue,
  classic insertion points, brain/memory study). UI packages copied from
  origin/feat-cmux-next into Packages/Shared (CmuxAgentQuestion, CmuxHomeCore,
  CmuxHomeRender, CmuxMessagesLab). Starting CmuxChief backend package.

## Standing rules (user directives)

- Up to 15 parallel subagents; exactly ONE PR; evaluator subagent rates each
  dev build 0-10 per parity area, iterate until every area is 9+.
- Before any design/UI decision (composer, sidebar, agent status, approvals,
  settings, first run/onboarding), consult the design references repo
  `/Users/cmux/manaflow/cmuxterm-hq/worktrees/cmux-design-references`
  (board.html, apps/*/README.md, topics/*.md, research/) and cite the reference
  used in the "Design references used" section below. Every subagent prompt
  carries this rule; the evaluator judges against these references too.

## Design references used

(path in cmux-design-references -> decision it informed)

- topics/approvals.md, apps/cursor/live/approval-command-pending.png,
  apps/t3-code/live/approval-command-and-thread-details.png -> approval card
  (caption, mono command, Deny/Allow ⏎, always-allow menu, receipt).
- topics/transcript.md, apps/cursor/live/transcript-tool-calls-expanded.png,
  apps/t3-code/live/transcript-expanded-tool-history.png,
  apps/codex/web/tools-running-progress.png -> quiet work rows, "Ran N commands".
- topics/sidebar.md, apps/codex/web/sidebar-parallel-agents.png,
  apps/claude/live/code-home-overview.png -> Home row style and the sidebar
  turning into the conversation list on Home (one navigation column).
- topics/first-run.md, research/first-run.md,
  apps/codex/web/first-project-prompt-starters.png -> first run = actions,
  Your agents, hint; 3 suggestion chips above the composer.
- topics/settings.md, apps/claude/live/model-picker-open.png,
  model-effort-submenu.png, apps/aside/web/reasoning-menu.webp -> settings
  panel (Default (resolved), effort captions, stats).
- apps/aside/web/memory-file-browser.jpg -> memory sheet + "Chief will
  remember · Undo".
- topics/status-and-progress.md, apps/t3-code/live/task-running-thinking.png
  -> "Working · 12 s" row, "Needs you" sidebar status.
- topics/home-and-empty.md -> transcript-only Home, composer as hero.

## Decisions

1. **UI = cmux-next's own code, vendored unchanged.** The iMessage transcript in
   cmux-next is `MessagesLabHome` (Packages/Shared/CmuxMessagesLab) over
   `CmuxHomeRender` + `CmuxHomeCore`. These are Shared packages with no CmuxNext
   dependency, so classic copies them byte-identical from origin/feat-cmux-next.
   That is the only way to get pixel parity (same rows, springs, morph, glass,
   header backdrop, tapbacks, swipe reply). A later sync is `git checkout
   origin/feat-cmux-next -- Packages/Shared/<pkg>`.
2. **Seam = `HomeSource`.** cmux-next feeds the UI through `HomeStore(source:)`.
   Classic implements its own `HomeSource` (`ChiefLocalSource`, new package
   `Packages/macOS/CmuxChief`): an in-process conversation owner that persists
   conversations as JSONL under the build's Chief home and turns a user message
   into a brain turn. No cmux-tui daemon, no acpmux.
3. **Brain = the user's chosen agent CLI, per turn, in-process driver.**
   cmux-next's optchat-chief needs the cmux-tui conversation owner + acpmux, which
   classic does not have; bundling the Rust stack would be a large, risky
   build change. Classic instead drives the agent CLI the user already has
   (Claude Code stream-json, Codex `exec --json`), resuming one CLI session per
   conversation, with Chief's system prompt and the `cmux` CLI as its tool
   surface (classic's terminals already export the control socket). Streaming
   text -> `HomeEvent.draft`; tool calls -> `.work` parts; stop -> SIGINT the
   turn's process group.
4. **Memory = local, inspectable files** in the Chief home (profile + notes),
   injected into each turn's system prompt and edited by the model through a
   `cmux chief memory` style command (details: report-brain).
5. **Model picker** persisted in cmux settings (`chief.harness`, `chief.model`,
   `chief.effort`), editable from Chief's settings sheet in the UI.

## Parity checklist

See `chief-parity.md` (local, not committed). State summary goes here.

## Next steps

- [ ] Packages build on build host (nx-remote) + Swift 6.0 notes
- [ ] CmuxChief package: store + brain drivers + memory + prompt
- [ ] App: Home button, Home view, Chief panel type, settings, shortcuts
- [ ] Tagged dev build, evaluator loop, PR

- 2026-10-15 continuation: submitted exact `d3f39f0bc0d31cea97f9452ba8d2aee2fdd39d52` to the fleet as `pr-21063-chief-cloud-v2` (job `ccb87e22b4b7f8598f41e7d3`, backend port 4197); build and publish are green. Dark and light dogfood tours were dispatched for this SHA (`38799307916`, `38799319342`) to capture screenshots and AX trees.
- Tightened the Cloud prompt locally so an agent auth preflight blocks launch when unauthenticated and gives explicit Device Code guidance; this remains unpushed until the in-flight d3f CI wait reports. The tagged app was re-launched with an isolated socket and Codex harness for a real cloud round.

- 2026-10-15 continuation: while the d3f39f0 CI wait remained active, added a red-before-green cloud prompt regression commit `2dc3f45e099` and local fix `68772e7a731`. Cloud guidance now uses absolute `/home/cmux/work/<slug>` guest paths for clone and launch, explicitly forbids pushing the HQ checkout or a parent worktree directory, and keeps the auth preflight gate and Device Code guidance. `python3 scripts/verify-local.py --affected` passes for the changed files (the committed follow-up also passes the feature-flag check). The dev backend VM inventory contains no `chief-dogfood-1` or other task-created VM; only the user's pre-existing machines remain.
- Started waits for the existing d3 dark/light dogfood tours (`38799307916`, `38799319342`) so their screenshots and accessibility artifacts can be attached to the same PR once complete.
- Checked the `cmux-sidebar-render-fixture` crash sentinel at `Packages/macOS/CmuxSidebarInterpreterService/Sources/cmux-sidebar-render-fixture/main.swift:76` against `origin/main`: it is byte-for-byte the same intentional `CMUX_SIDEBAR_RENDER_FIXTURE_CRASH_TOKEN` test hook, so that failure is baseline behavior rather than a PR regression.
- Added local commit `3a9aa6c8a95` to make the light Chief dogfood tour emit AX trees at first-run, approval, settings, and split-pane checkpoints in addition to its screenshots.

- 2026-10-15 follow-up: `6f774ea0ee1` hardens the Home conversation-list fallback. While the asynchronous tail read is in flight, Chief no longer exposes InboxRow's raw tool/question projection; only a pending user's own message or a human-readable committed bubble can become the preview. Swift syntax verification against origin/main passes.
- 2026-10-15 follow-up: `e00ae4627e1` adds the shell `$` cue to pending command approvals and a descriptive Always Allow tooltip on the chevron; MessagesLab's focused Chief notice suite passes. It is pushed with the preview hardening on the same PR; the exact-head wait is running.
- PR body refreshed for `e00ae4627e1`: the dogfood guide now calls out the human-readable preview fallback and approval `$`/Always Allow affordances, and its validation/checklist points at the exact pushed head.

- 2026-10-15 current-head validation: the focused MessagesLab Chief slice (`swift test --package-path Packages/Shared/CmuxMessagesLab --filter 'Chief|MessagesLabHomeTests.Chief' --disable-sandbox`) passed 57 tests, including cloud question receipts, machine-name rendering, failure precedence, sign-in state, Stop Machine, previews, header reveal, bottom inset, light palette and AX-related row behavior. The unfiltered local HomeHarness motion golden remains a known macOS 15 Core Animation timing mismatch against the macOS 26 golden; no vendored timing change was made.
- 2026-10-15 PR guide correction: the PR body now distinguishes the retained first cloud screenshot capture from the current round-two tagged re-test. The latter verified guest naming, `/home/cmux` auth preflight, Device Code guidance and VM cleanup; focused tests cover the current answered-card, named-machine, failed-command and Stop Machine UI behavior.
- 2026-10-15 UI polish: local commit `494dc0553a7` keeps the Open Chief shortcut visible in workspace mode beside the Chief row's status, so the keyboard route is discoverable without hover and survives AX captures. The Chief settings panel's bottom fade now includes a tinted down-chevron scroll cue. `verify-local.py --affected` and Swift syntax parsing against `origin/main` pass; no new localization keys were added (the repository-wide localization audit still reports its existing catalog debt).
- 2026-10-15 AX follow-up: `3bcf9b4a356` includes the visible Open Chief shortcut in the Home row's accessibility value while retaining the localized status text. The single-file Swift syntax check passes.
- 2026-10-15 approval AX follow-up: `f0c3ba32277` labels the Always Allow chevron with its scoped rule (for example, “Always Allow cmux chief dispatch …”) so VoiceOver exposes the same action as the visual tooltip. The focused Chief row suites (34 tests) and Swift syntax check pass.

- 2026-10-15 catalog/unread polish: unknown custom model ids now leave the effort picker at the model's default instead of offering every explicit level, because capabilities are not known until the CLI catalog catches up. Added package coverage. Home marks the selected conversation read as soon as an active, mounted view opens it (including before the window becomes key), while hidden or inactive Home leaves unread state intact; added a focused predicate test. `swift test --package-path Packages/macOS/CmuxChief --disable-sandbox` passes 179 tests; affected verification and Swift syntax pass.
- 2026-10-15 follow-up: normalized persisted Chief settings now clear an effort flag when the selected model does not advertise it (including unknown/custom model ids and GPT-5.5's unsupported `max`), so an old selection cannot leak an invalid `--effort` into a later turn. Added coverage and pushed `0d9854e7a61`.
- 2026-10-15 CI audit: read the complete failed log for run `38797338970`. Chief package failures were the stale SwiftPM localization-bundle assertion and an attachment fixture that accepted an ImageIO writer without a decodable sample; both are fixed by `5e96e25a441`/`9d9ff092493` and pass in the current package tests. The app-host shard failures were unrelated ratchets: LaunchServices enumeration/setup in shards 2 and 4, detached browser-inspector persistence in shard 1, and stationary sidebar pointer churn in shard 3. No Chief target-wiring failure was present.
- 2026-10-15 PR follow-up: pushed `0d9854e7a61` and started the exact-head background wait `glaeda-gh wait pr manaflow-ai/cmux#21063 --jobs --until done --sha 0d9854e7a61`. Refreshed the PR body with the v5 fleet dogfood guide, current validation and known gaps.
