# Data flow: tabs, attachments and the audit majors

Branch `feat-cnx-ios-dataflow`, 2026-10-14. This covers blockers B6, B7 and B8
and the unowned majors in `production-audit.md`.

## Setup for the live run

- **Mac:** a real cmux-next app, built by the fleet from this branch:
  - job `3cefb61941d16ba2f3542cd5`, commit `b76afdc96460`, tag `cnxdf`;
  - app "cmux DEV cnxdf", run on this Mac, hidden (`open -g -j`);
  - its bundled `cmux-mobile-host` (version file `commit=b76afdc96460`), supervised by
    the app (`CMUX_MOBILE_CONTROL=stdio`), with its own cmux-tui daemon
    (`cmux-app-cnxdf`) and acpmux.
  - The app set `CMUX_MOBILE_AGENT_TAB_HOST=install:mac-3649db2c-…` itself.
  - Sign-in used the dev account through `CMUX_UITEST_STACK_EMAIL`/`_PASSWORD`.
  - No standalone hostd, stub daemon, fake agent or `MockMacLink` was used.
- **Phone:** one simulator, `cmux-mobile-dataflow` (iPhone 17 Pro, iOS 27.0), deleted
  afterwards.
  - Debug build of this branch, signed in to the same dev account.
  - Pinned to this Mac with the launch argument
    `-cmuxMobile.live.mac.<team> <mac device id>`.
  - Real HID taps and typing through `axe`.
  - The link was WebRTC direct.
- **Agent:** the real Claude Code harness in the Mac's acpmux. No scripted agent.
- **The person's own steps on the Mac** (see B6 below):
  - added `~/cnxdf-work` to acpmux `webRoots`, in the tag's own `config.json`;
  - trusted that folder through acpmux's local socket (`acp.trust.set`), the
    same answer the Mac app's trust prompt gives.
  - Both were undone afterwards: the config was restored and the folder
    removed.

Evidence (screenshots and logs) is in `/tmp/cnxdf/` on the run Mac and is not
committed. The file names below are in `shots/`.

## Result per item

| Item | Result | Evidence (real-build live run) |
| --- | --- | --- |
| B6 new terminal tab | **Pass.** `new-tab {pane}` created `s9` (pty) on the Mac. The phone showed it only once the Mac listed it, and attached at once. Typed commands ran on the Mac. | `07-new-terminal.png`, `08-terminal-typed.png`; the Mac daemon tree showed `workspace-1 pane 7 s9 pty` |
| B6 new browser tab | **Pass.** `new-browser-tab about:blank` created `s12` on the Mac. | `31-browser.png`; tree `s12 browser` |
| B6 new Claude chat | **Pass.** acpmux `session/new` (asking policy, no MCP servers), then `new-conversation-tab`. hostd stamped this Mac's host. The Mac's tree shows `s11` with `{"harness":"claude","host":"install:mac-3649db2c-…","session":"01a138a3-…"}`, the same host as the Mac's own agent tabs. The chat opened ready to type and answered. | `21-12.png`, `29-reply.png` |
| B6 refusals are visible, nothing phone-only is added | **Pass.** These came back as toasts, and no tab was added: no terminal folder ("Open a terminal tab first"); a folder outside acpmux's web roots; an untrusted folder ("Trust this folder on your Mac first"); a folder outside home (acpmux remote chain). | `06-claude-nofolder.png`, `17-2.png`, `18-2.png`, `19-2.png` |
| B6 close tab | **Pass.** `close-surface` removed `s6` and, later, browser `s12` from the Mac's tree. | tree before and after |
| B6 tabs survive a refresh | **Pass.** After a relaunch of the phone app, the grid listed the three Mac tabs, and the chat history was intact. | `32-relaunch-grid.png`, `33.png` |
| B6 select | **By design, phone-local.** The phone remembers the last tab per workspace. It never sends `select-tab`/`report-focus`, because both move the Mac's view. See `SECURITY.md`. | — |
| B6 Codex chat | **Not offered.** acpmux refuses a remote start for Codex and opencode (`REFUSED_FAMILIES`), so the menu lists only Claude. | `05.png` |
| B7 terminal photo | **Pass.** A Photos pick was uploaded over `upload` into `<tab cwd>/.cmux/attachments/phone-<session>/Photo 2026-10-13 at 21.16.21.jpeg`. It is byte-identical to the source (`cmp`). The real quoted path was typed without Return; Ctrl-C then cancelled the line, which proves it never ran. | `11-attached.png`, `12-uploaded.png`, `20.png`; hostd `upload saved size=15212` |
| B8 chat file and photo | **Pass.** `cmux-mobile-note.txt` was uploaded and sent as an ACP `resource` (text plus `file://` URI). The photo was sent as an ACP `image` block. Real Claude answered "The secret word is TANGERINE-42, and the photo shows … ice plant flowers". | `27-draft.png`, `29-reply.png` |
| B8 upload lands in the session folder | **Pass after a fix.** The first run sent the summary's display path (`~/…`), so the file went to hostd's uploads folder. The source now uses acpmux's absolute session folder. The rerun saved `~/cnxdf-work/.cmux/attachments/phone-b44e…/cmux-mobile-note.txt`, and Claude read it. | `34-file2.png` |
| B8 visible failure | **Unit-tested.** A failed upload or a send while the link is down emits `promptNotSent`: the draft and attachments return to the composer, with the reason. | `PromptBlockTests`, `ChatComposer` restore |
| Majors: dead settings | Wired: font size, wrap code, key clicks, dismiss keyboard after send, follow-up queue or steer. Removed: terminal theme and connection details. Settings shows "Terminal 12 pt" and "Composer Queue". | `35-settings.png` |
| Majors: sign-in methods | Real linked providers from Stack: GitHub, Apple, Google, Email code, Password. | `36-account.png` |
| Majors: team members | Loaded from Stack with loading and error states. The personal space shows only you, as live. A Stack team was not available to this account, so a multi-member team was not checked. | code and unit tests |
| Majors: Feed pull-to-refresh | Re-reads the Mac's sessions and open asks (`LiveFeed.refresh`). The Feed showed both live turns after the pull. | `38-feed.png` |
| Majors: Feed with no Mac | Fails visibly ("Nothing was sent"); never marks an item answered locally. | `FeedRefreshTests` |
| Majors: checkpoints | Hidden in the chat page menu and in the tab page menu unless the source supports them (only the DEBUG mock does). | menu code |
| Majors: plan mode, "Changes", Stop | The plan toggle uses the advertised modes and hides without one. "Changes" is renamed "Agent edits" and is disabled when there are none. Stop is enabled only while running. | `PreferencesAndModesTests` |
| Majors: team color, acknowledgements, dead fakes | Settings uploads the color through the sidebar's path. Acknowledgements list the real dependencies. The mock user, demo directors and mock terminal are compiled out of Production, and `check-production-binary.sh` rejects them. It passed on the Production build. | `check-production-binary.sh` output |
| Majors: silent drops | A prompt sent with no link returns the draft. An answer to a question that is gone now says so. | `AcpmuxHub` |

The live run was at `a2ea6b60` (Mac app at `b76afdc9`). The later merge of
`origin/feat-cnx-ios` (browserstream, prodinfra and others) touched the same
Settings, shell, tab source and hostd files. After the merge, the hostd tests
pass, and the iOS Debug and Production builds succeed (with the xcframework
rebuilt). The merge was not run live again.

## Tests

- `cargo test -j 4 -p cmux-mobile-host`: 18 unit and 4 integration tests pass.
  - New unit tests: policy `agent_tabs_*`, `upload_names_are_safe`,
    `publish_never_replaces`, `acpmux_messages_are_joined`.
  - New integration cases in `services_over_*`:
    - a 600 KB acpmux message joined;
    - the agent tab host rewrite;
    - uploads to the uploads folder and to a workspace folder;
    - refusals for a foreign folder and an oversized file.
- `cargo clippy -D warnings` and `cargo fmt --check` are clean.
- `mirrors_the_swift_allowlist` passes with `new-conversation-tab` in both
  lists.
- Swift: the iOS Debug and Production simulator builds succeed.
  - The cmux-next app compiled in the fleet build, which includes
    `MobileHostLaunch.agentTabHost` and its test.
  - The new Swift Testing suites were not run: `nx-remote` could not resolve
    `cmux-lawrence-2`, and local `xcodebuild test` is not allowed. They need a
    CI or build-host run.
  - New suites: `WorkspacesTests` (tab create, close and refusal),
    `PromptBlockTests`, `FeedRefreshTests`, `AccountDetailsTests`,
    `PreferencesAndModesTests`.

## Open findings

- **Sent attachments in the transcript.** The user bubble does not show the
  file or photo chips from acpmux's records. A file-only prompt shows an empty
  bubble (`34-file2.png`). This is the record mapping in `AcpmuxRecords`.
- **Where a phone can start a chat.** acpmux's remote guard admits only a known
  project (a folder with a local session) or a `webRoots` folder, inside home
  and trusted. A fresh folder therefore needs one step on the Mac first. The
  phone says which one.
- **Uploads.** There is no per-phone quota or cleanup of old uploads; see
  `SECURITY.md`.
- **hostd copies.** This branch's hostd still lacks machost's `F_GETPATH`
  re-check and browser URL narrowing. The upload, agent tab and joining
  changes here need to be merged into machost's copy too.
