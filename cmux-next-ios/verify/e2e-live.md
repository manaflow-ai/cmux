# Live end to end against a real Mac

Branch `feat-cnx-ios-e2e`, 2026-10-13. The live paths after the user paired
a real iPhone with a real Mac for the first time. Many of them had only run
against fakes. Evidence is git-ignored, in
`verify/evidence/2026-10-13/e2e-live/`. File names in the matrix are in that
folder.

## Setup

- **Mac**: `mini-cmuxs-mac-mini-2`, user-local under `~/cmux-next-ios-e2e/e2e`. It
  was stopped and the token removed afterwards. `verify/scripts/e2e-mac.sh
  start|stop|hostd-stop|hostd-start` runs these:
  - a real `cmux-tui` daemon (session `mobile`);
  - `acpmux` with the credit-free agent `verify/scripts/e2e_agent.py`. That
    is acpmux's own `tests/fake_agent.py`, plus `edit: PATH` (a real file
    edit reported as an ACP `diff`) and `stream: N`. No model was called.
  - `cmux-mobile-host`, built from this branch. Its hostd sources are the Mac app's
    (`feat-cnx-ios-machost`). It ran in the personal space as "mobile e2e mini 2".
  - Seeding: workspaces `cmux-mobile-demo` (terminal plus an agent tab started with
    `agent-session-start`) and `notes`.
- **Account**: the 1Password item could not be read, because `op` timed out
  waiting for app approval. The coordinator directed the DEBUG dev credential
  from `CmuxAuthRuntime` instead, as in `live.md`. The refresh token stayed
  in 0600 files and reached the mini over ssh stdin. Nothing was printed.
- **Phones**: headless `cmux-mobile-e2e-ios26` (iPhone 17 Pro, iOS 26.5) and
  `cmux-mobile-e2e-ios27` (iOS 27.0), Debug build. Simulator.app was never opened.
  Real HID taps and typing came from `axe`; no demo driver was used.
  - Typing with `axe` makes iOS treat a hardware keyboard as attached. The
    soft-keyboard runs used an erased `cmux-mobile-e2e-ios26` and taps only.
- **Transport**: WebRTC was the main path. Note that `wgperf-mini` (another
  agent's relay benchmark) shared the same personal TeamHub. The Mac's
  signaling socket was reset twice by the peer (`Connection reset by peer`)
  while it answered an offer, so two dials waited the full 26 s before a
  retry connected (`mac-hostd.log` 21:32-21:33).

## Feature × result

| Feature | Result | Evidence |
| --- | --- | --- |
| Workspaces list, presence, live status line | Pass. "mobile e2e mini 2 · Connected · WebRTC direct · 1 ms" | `s26-1.png`, `w1.png` |
| Open workspace on its last tab | Pass. The agent tab reopens on the agent, and the terminal on the terminal | `s27-11.png`, `r2.png` |
| Tab grid, switch tabs | Pass | `s27-5.png` |
| Create workspace: tap (instant) | Pass. "New Workspace" was created on the Mac and opened on its live terminal | `wn1.png` |
| Create workspace: hold menu | Pass. Live shows New Workspace and New Browser Workspace (hostd refuses `cwd` and agent starts). The browser start made a pty + browser workspace | `wn3.png`, `wn4.png` |
| Live terminal tab | **Was mock**. Fixed (1) | `s26-2.png` before, `s26-3.png` after |
| Terminal: composer, direct typing, arrows, Esc, ^C | Pass. Every keystroke reached the Mac (`read-screen` matches) | `s26-4.png`, `k13.png`, `k16c.png` |
| Terminal: scrollback, jump to bottom | Pass | `k10.png` |
| Terminal: reattach (relaunch, new link) | **Prompt mid-screen, typing overwrote it, then a blank page**. Fixed (2) | `k1.png`/`k2.png` before, `k10.png` after |
| Terminal: TUI (vim) on the alternate screen, pinned | Pass. Status line above the composer | `k12.png`, `v1.png` |
| Terminal: after leaving vim | **Output froze**. Fixed (3) | `v2.png` |
| Terminal: keyboard show/hide (soft keyboard) | Pass. The stack rides the keyboard, frame by frame | `frames/s3.png`, `frames/fr-kbhide26/` |
| Terminal: hardware keyboard | **Composer jumped to the top, page blank**. Fixed (4) | `h3.png` before, `h7.png` after |
| Terminal: Files and Links over `file` | **Mock files**. Fixed (1). A real `main.rs` previewed from the Mac | `fl3.png`, `fl5.png` |
| Agent tab streaming from acpmux | Pass. 40 chunks in 5.1 s, Stop shown while running | `st2.png` |
| Agent composer: tap "Follow up" | **Did nothing**. Fixed (5) | `ag2.png` |
| Permission: Allow (refused), then Reject | Pass. Reject reached the Mac ("chose no"). **Refusal banner stayed**: fixed (6) | `p2.png`, `p3.png` |
| Question: answer (refused) | Refused for a phone, as designed (`live.md` finding 1). **No way to decline**: fixed (6) | `f2.png` |
| Question: Decline | Pass. The Mac got `reject_once` ("chose reject_once") | `ed2.png` |
| Feed: live events, inline answer, refusal shown | Pass | `f1.png`, `f2.png` |
| Diff viewer on a real edit | **File list did not open a file**. Fixed (7) | `df4.png` |
| Artifacts browser, file preview | Absolute path: pass. **Relative path refused**. Fixed (8) | `ar2.png`, `ar3.png`, `ar4.png` |
| New chat tab (no session yet), then Mac starts it | **"This chat hasn't started on the Mac yet" forever**. Fixed (9). Verified live: the open tab turned into the chat and answered | `un2.png`, `un4.png` |
| Transport WebRTC ↔ WireGuard | Pass. WireGuard was relay then direct in 2 s; back to WebRTC in 2.5 s. The terminal reattached after each switch | `w1.png`, `r2.png` |
| Mac offline / online (hostd stop/start) | Online again in 4 s. **Banner named the wrong Mac**. Fixed (10) | `off1.png`, `on1.png` |
| Background 45 s / foreground | **Dead link unnoticed for 20 s, keystrokes lost**. Fixed (11). After the fix: redial within 8 s, and text typed after foreground reached the Mac | `bgtest.out`, `s27.log` |
| Terminal top bar (iOS 26) | **Scrollback under the clock**. Fixed (12) | `k2.png` before, `td26.png` after |

## Root causes and fixes

1. **Terminal tabs ran the mock.** `ShellView` kept the `LiveCoordinator` it
   was built with. RootView creates the coordinator after the account
   resolves (a restored session or an auto sign-in), so the shell's coordinator
   was nil:
   - every terminal tab used `MockTerminalSession`;
   - live workspace creation was never wired;
   - Files and Links used mock files.
   `ShellModel.attach(live:)` now follows the coordinator, and a mock host is
   replaced once the tab is live. Terminal artifacts use
   `LinkFileArtifactSource` with the tab's absolute cwd (`DaemonTree.directories`).
2. **Mirror geometry.** The phone's Ghostty surface is about 151 rows (the
   screen plus scroll margins). The Mac's terminal is the TUI grid (42 rows).
   The daemon replay ends with `CUP 42;30`, which landed mid-mirror.
   `TerminalRowShift` maps the remote primary screen onto the bottom rows:
   - a reset followed by line feeds;
   - CUP, VPA and DECSTBM rows shifted;
   - the alternate screen untouched.
   Separately, a cursor probe restored an old viewport row with nobody asking
   again, which left a blank page. The controller now re-requests whenever a
   report leaves the visible rows uncovered.
3. **vim's scroll region** (`1;42`, shared by both screens) survived the exit,
   so bottom-row output never scrolled. Leaving the alternate screen resets
   the margins (`ESC 7 ESC [r ESC 8`). Focus also survives moving the surface
   into and out of TUI mode.
4. **Hardware keyboard.** The keyboard layout guide reported a 0-wide 44 pt
   frame at y 172. The stack's guide constraints now apply near the bottom
   edge only (`setConstraints(_:activeWhenNearEdge:)`).
5. **"Follow up" capsule.** The tap set focus before the TextField existed, so
   SwiftUI dropped it. The composer now expands first, then focuses.
6. **Questions.** A phone can only decline, so there is now a Decline action:
   - in the chat, under the question card;
   - in the Feed cell, after a refusal;
   - as the Feed trailing swipe.
   It sends the question's reject option. A new answer clears the last
   refusal.
7. **Diff file list.** It used `NavigationLink(value:)` inside the workspace
   stack's typed `[Workspace]` path, where it never pushes. The push is now
   state driven. The count also reads "1 file".
8. **Artifacts.** The summary's cwd is the workspace's display path (`~/…`).
   Relative references now resolve against acpmux's absolute session folder,
   and an absolute edit path and its relative mention collapse into one row.
9. **Unbound chats.** A store built before the tab had a session was cached
   for good. The coordinator now records the session each store used and
   rebuilds it when the tree binds another (`bind-conversation-tab-session`,
   `agent-session-start`).
   - The copy now says what to do: "<Agent> hasn't started in this tab yet.
     Send the first message from cmux on <Mac>; the chat continues here."
   - It repeats when a prompt is sent.
   - The phone does not start the chat itself. A Mac chat starts at its
     first send in the Mac app, and the daemon starts only `registry:` tabs.
     Allowlisting `agent-session-start` for a phone is a policy decision
     (#13742).
10. **Offline Mac.** When the linked Mac went offline, the target fell back to
    the list's first Mac (offline for 15 h). `LinkMachine.target` now keeps
    the linked Mac.
11. **Foreground probe.** It raced the ping and the timeout in a task group,
    which waits for all children; the FFI ping ignores cancellation.
    `LinkController.race` returns the first result instead.
    `DaemonTerminalSession` reattaches on every new link (`reconnect()`) and
    requeues input whose request fails with the channel.
12. **iOS 26 embedded terminal.** It now has a solid status-bar band with a
    short fade (iOS 27 keeps the system soft edge).

## Layout gaps

- **Terminal tab top bar**: fixed for iOS 26 (12). On iOS 27 the system soft
  edge already acts as the bar (`tops.png`, top half).
- **TabsKit toolbar covering the terminal composer**: not reproduced on the
  soft keyboard (iOS 26) or the hardware keyboard (iOS 27). In the
  hardware-keyboard runs the stack jumped to the top instead (4). In the
  soft-keyboard runs the composer stayed 8 pt above the capsule, and the
  keyboard covered the toolbar (`frames/s3.png`, `sk2.png`, `kh1.png`).
- **Agent transcript about 20 pt off its margin while the composer is
  expanded**: not reproduced (focus with the soft keyboard on iOS 26, an
  attachment, typing on iOS 27; `ag2.png`, `at1.png`). The text stayed at
  20 pt. `feat-cnx-ios-kbd` owns keyboard and viewport layout in
  CmuxMobileAgentChat, so it was not changed here.

## Open findings

- **Feed history.** The Feed is empty after a relaunch: it shows only events
  since the watch started, plus asks still open (`fd1`).
- **Wrapped paths.** Files and Links reads soft-wrapped paths as two
  references (`/live/work/demo/README.md`).
- **New-workspace prompt.** A new workspace's terminal once lost its first
  prompt's text on the phone after the 80 to 54 column resize. A reattach
  replay was correct.
- **Agent page under the status bar (iOS 26).** The agent page has no top
  effect there either; this is for the CmuxMobileAgentChat owner.
- **Stale Macs.** Duplicate stale Macs from earlier runs fill the list. There
  is no forget action.

## Tests

`swift test` in `cmux-next-ios/CmuxMobileKit` (macOS) passes all 110 tests. New tests:

- `DaemonTerminalSessionTests.reattachesAfterTheLinkDrops` and
  `detachedEventEndsTheTerminal`;
- `TerminalRowShiftTests` (5 tests);
- `AgentChatTests.answeringAgainClearsTheLastRefusal`;
- `FeedQuestionDeclineTests`;
- `ParityTests.absolutePathsAndRelativeReferences` (display folder);
- `MacTargetTests`;
- `ProbeRaceTests`.

The iOS-only shell, controller and coordinator changes were verified live
(matrix above).
