# ACP parity, session artifacts, Feed swipes: verification

Branch `feat-cnx-ios-acp`, 2026-10-13. Modules: the new `CmuxMobileArtifacts`, `CmuxMobileAgentChat`,
`CmuxMobileFeed`, `CmuxMobileLive` (acpmux mapping), with one-line hooks in `CmuxMobileTerminal`
(re-export), `CmuxMobileWorkspaces` (tab menu) and `CmuxMobileShell` (demo launch argument).

## What was built

| Area | What | Where |
| --- | --- | --- |
| Session artifacts | `CmuxMobileArtifacts` module: the reference model and extractor, mock, inline and link sources, the browser (chips, list or Library-style grid) and previews (HTML in a web view with a Source toggle, Markdown, code with line numbers, zoomable image, autoplaying video, PDF, web link with Open in Safari, folder listing, binary card). Moved out of `CmuxMobileTerminal` with public names unchanged; `CmuxMobileTerminal` re-exports it. | `CmuxMobileArtifacts/` |
| Agent-session collection | `SessionArtifacts.collect` gathers every path, folder, URL and image the session referenced: tool-call locations, edits and created files (diff paths), input paths and URLs, shell and search output, image content blocks, resource links, attachments, links and paths in prompts, answers and plans, and the same inside subagents. A stronger mention wins the label ("Edited" over "Read" over "In the answer"). | `CmuxMobileAgentChat/SessionArtifacts.swift` |
| Live previews | `LinkFileArtifactSource` opens one `file` channel per preview (`{"path"}`, PROTOCOL.md), resolves relative paths against the session's folder, caps at 24 MB, and explains refusals (`not_found`, `forbidden`, folders, offline). Attachments and tool images are served inline. | `CmuxMobileArtifacts/LinkFileArtifactSource.swift`, `AcpmuxSessionSource.artifactSource` |
| Entry points | Chat title menu "Files and artifacts" and the More menu; workspace tab menu "Files and Artifacts". | `AgentChatScreen.swift`, `WorkspaceTabsSource.swift` |
| Subagents | `_meta.acpmux.subagents` and `_meta.acpmux.subagent` (acpmux `subagents.rs`) become `.subagent` / `.subagentUpdate` events. The store keeps each subagent's own transcript. Subagents spawned with no prose between them form one group card; their spawn tool calls are hidden, as in the web UI. List screen (nested indent), subagent transcript ("Subagent of" pill, task bubble, the chat's row rules, nested groups). | `Subagents.swift`, `ParityViews.swift`, `AcpmuxRecords.swift` |
| Checkpoints | List (before and after each turn, branch, head, file count, partial warning), swipe or tap to restore, confirmation dialog, toast, safety checkpoint. Live: acpmux has no checkpoint method (checkpoints are the cmux app's `git.checkpoint.*`), so the screen shows "Checkpoints unavailable" with the reason. | `ParityViews.swift`, `AgentParity.swift` |
| Handoff | Pick a harness (`_acpmux/harnesses`; unavailable ones disabled with the reason), review: from and to glyphs, carried context (coverage), repository checkpoint reference with the attestation toggle, editable capsule with a byte counter, sticky "Continue in X" button, Discard. Live: `_acpmux/handoff_prepare`, `handoff_start` (checkpoint attested), `handoff_discard`; refusals such as `source_busy` show as sentences. | `ParityViews.swift`, `AcpmuxHub.swift` |
| Feed swipes | Mail conventions on the `LazyVStack` Feed: a horizontal-only pan (never fights scrolling), actions under the row, a full swipe past 60 % performs the outermost action with a haptic, rubber banding, tap to close, one row open at a time, scroll closes. Leading: Allow (permissions), Answer (questions), Read or Unread. Trailing: Deny or Done, then Open. Done hides the event with an Undo bar for 4 s. VoiceOver gets the same actions as accessibility actions. | `FeedSwipe.swift`, `FeedScreen.swift`, `FeedStore.swift` |
| Composer | Camera through `UIImagePickerController`; on devices without a camera (simulators) the menu item is disabled with "No camera on this device". The mic button is gone: iOS has no API to start keyboard dictation, and the keyboard's own mic dictates into the field. `NSCameraUsageDescription` added. | `ChatComposer.swift`, `project.yml` |
| Release -O link | Fixed (see below); the Demo configuration builds with -O again. | `CmuxMobileDesign/States.swift`, `project.yml`, `scripts/demo-build.sh` |

## Release (-O) link failure: root cause and fix

`ld: Undefined symbols: opaque type descriptor for <<opaque return type of View.task<A>(id:name:priority:file:line:_:)>>`, referenced from `CmuxMobileSettings.o`.

- In the iOS 27 SDK, `View.task(id:name:priority:file:line:_:)` is `@export(implementation)`
  (always emitted into the client) and its opaque return type depends on
  `if #available(iOS 26.4, …)`, so the underlying type is chosen at run time through the
  opaque type descriptor. SwiftUI exports no such symbol; every module that calls it
  emits a private (hidden) copy.
- At -O, Swift's default cross-module optimization serialized `CmuxMobileDesign`'s public
  `cmuxMobileToast(_:)` modifier, which called `.task(id:)`, and inlined it into
  `CmuxMobileSettings`. `CmuxMobileSettings` then referenced the descriptor without emitting its own
  copy, and `CmuxMobileDesign`'s copy is hidden. -Osize does not serialize, which is why it
  linked. Confirmed with `nm`: the descriptor is "non-external (was a private external)" in
  `CmuxMobileDesign.o`, `CmuxMobileShell.o` and `CmuxMobileTerminal.o`, and undefined in `CmuxMobileSettings.o`.
- Fix: the toast body is a `private struct ToastHost: View`. Code that references a private
  type is never serialized across modules, so the descriptor stays in `CmuxMobileDesign`. The
  rule for later code: keep `.task(id:)` (and `.task {}`) inside private or internal views,
  not in public modifiers.
- Verified: Release `generic/platform=iOS Simulator` and Release `generic/platform=iOS`
  (unsigned) link at -O; the Demo configuration links at -O. `demo-build.sh` now builds
  -O and falls back to -Osize only for refs before the fix.

## How it was verified

- `xcodegen generate`; Debug simulator build; Release and Demo builds at -O.
- Headless simulators, iPhone 17 Pro: `cmux-mobile-acp-ios26` (iOS 26.5) and `cmux-mobile-acp-ios27`
  (iOS 27.0). Simulator.app was never opened. Mock auth (`CMUX_MOBILE_MOCK_AUTH=1`).
- `verify/record-acp.sh <udid> <label> <dark|light> [seconds] [phases]` installs the Debug
  build, records with `simctl io recordVideo`, launches `-CmuxMobileDemo acp-parity`, and splits
  frames. The DEBUG driver (`CmuxMobileFeed/ParityDemoScript.swift`) posts `DemoDirector`
  commands that each screen runs through its own state: Feed swipes (Done with Undo,
  Allow on a permission, Answer on a question, Read), then in the Claude chat the
  artifacts browser (HTML with Source, Images filter, grid, image, video, PDF, code), the
  subagents list and a subagent with a nested one, a checkpoint restore with
  confirmation, and a handoff to Codex (attest, start).
- Recorded dark and light on both simulators. Evidence (git-ignored):
  `verify/evidence/2026-10-13/acp/{ios26,ios27}-{dark,light}/` (`demo.mp4`, 2 fps
  `frames/`, contact `sheets/`), comparisons in `acp/compare/`.
- Unit tests (Swift Testing, macOS `swift test`): subagent folding and grouping, the
  artifact collector over the mock history, path resolution, link-file decoding, mock
  checkpoints and handoff, acpmux subagent attribution, harness and handoff record
  parsing. All pass (CmuxMobileAgentChatTests 13, CmuxMobileLiveTests 23, plus the model, transport and
  Chief suites). `CmuxMobileTerminalTests` (Ghostty's macOS link) and `CmuxMobileWorkspacesTests`
  (`WorkspaceSort` is iOS-only) do not build for macOS; both failures predate this branch,
  so those two targets were left out of the macOS run.

## Frame review: what changed after the recordings

1. Demo commands stopped after the first pushed screen: SwiftUI stops updating views
   under the top of a navigation stack. Every parity screen now listens, and the surface
   runs each command once (by serial).
2. The trailing toolbar button for artifacts crowded the two-line title; it moved into the
   More menu (the title menu has it too).
3. Code previews sat vertically centered in the 2D scroll view: anchored top-leading.
4. Videos opened paused: they autoplay now.
5. The Allow full swipe slid back while the card collapsed, drawing an L-shaped green
   block for a frame: content-changing actions now run after the row settles; Done runs
   while the row is out.
6. The handoff's start button was below the fold: it is a bottom `safeAreaBar` button;
   the checkpoint section moved above the long capsule editor.
7. Claude and Codex both showed "C": harness glyphs (as Feed avatars) replace initials.
8. "1 files left out", "Before “Restore”": fixed copy.

## Comparisons

| Check | Reference | Result |
| --- | --- | --- |
| Artifacts grid and chips | `chatgpt-26-library-grid` | Match: chip row, 2 columns, 1:1 tiles radius 16, 8 pt gaps. Ours adds the name and how it was referenced under each tile. |
| Artifacts list | `chatgpt-22-uploaded-files-empty` | Rows with type glyph, name, origin and path; previews push in the sheet's own stack. |
| Chat More menu | `chatgpt-21-chat-more-menu` | "Files and artifacts" first, then Share transcript and Stop agent (disabled while idle). Archive was removed: the link has no archive call. |
| Swipe actions | iOS Mail conventions (no capture in the reference set) | Leading blue Read, trailing purple Done outermost, gray Open, full-swipe arming with haptic; Undo bar like Mail's. |
| Checkpoint restore | web acpmux checkpoints (no phone reference) | Destructive "Restore Files" confirmation; the conversation is not changed. |
| Handoff review | web acpmux handoff `ReviewMessage` | Same sections and copy (Carried context, Repository checkpoint, the attestation sentence, Continue in X, Discard continuation). |

## Known gaps

- Live checkpoints: acpmux has no checkpoint API (the cmux app owns `git.checkpoint.*`), so
  the phone shows why. Wiring needs a daemon or cmux-mobile-host method and an allowlist entry.
- Live handoff start may be refused for remote callers by the Mac's policy; the refusal
  shows under the form. Not exercised against a live Mac in this pass.
- Live artifact previews need `cmux-mobile-host`'s `file_roots` to include the session folder; a
  `~/` working directory cannot be resolved on the phone. Folder listings over the link
  are not in the protocol.
- iOS 27's `swipeActionsContainer()` would replace the custom swipe once the deployment
  target is 27.
- Dictation is the keyboard's mic (no composer mic).
