# Codex CLI in terminal tabs: verification pass 1

Rig: cmux-next-ios/verify/e2e (hidden tagged cmux-next DEBUG Mac app from origin/feat-cnx-ios-mactry 1d56a3d7,
fleet tag cmux-mobile-e2e-1d56a3d7) + iOS app (Demo config) from feat-cnx-ios-codexqa
(origin/feat-cnx-ios + origin/feat-cnx-ios-design-terminal d7bf4d01) in a headless iOS 26.5 iPhone 17 Pro simulator.
Real Codex CLI (codex-cli 0.162.1) runs in the rig Mac's workspace terminal.

Status: pass 1 complete (2026-10-14, 11:16-12:25 PDT; 1-min load 3.6-34.8, under 40 for every timed step).

## Findings (ranked)

### F1 BLOCKER: the composer's Send never submits a prompt to Codex
- Steps: Codex idle at its `›` prompt. Tap the composer, type `write a 120 line python script ...`, tap Send.
- Expected: Codex starts working on the prompt.
- Actual: the text lands in Codex's input box with a soft newline after it (cursor on an empty second line);
  nothing runs. A second Send (empty composer = bare Return) submits it. Reproduced 4/4
  (`reply with the numbers 1 to 250 ...` also needed the second Return).
- Evidence: `artifacts/shots/s3-scrolled-during-stream.jpg` (draft stuck, cursor on new line, 60 s later),
  `artifacts/shots/s3-after-done-still-scrolled.jpg` (still stuck 88 s later); Mac screen read confirms
  `› write a 120 line ... your reply` followed by an empty input row and no `Working`.
- Also with the composer keyboard's own return key: `say hi` + return sent the line and left it unsubmitted
  in Codex; `in two words` + Send likewise (4/4 composer sends failed; every bare Return submitted).
- Direct typing on the soft keyboard + its return key submits fine (`artifacts/sheets/s2-direct-prompt.jpg`).
- Suspected area: `CmuxMobileTerminal/Ghostty/TerminalSurfaceView.swift` `sendText(_:pressReturn:)` sends the text as
  plain key text and then Enter immediately; Codex's paste-burst detection treats an Enter that arrives within a
  burst of un-bracketed characters as a newline. Send the composer text as a bracketed paste (the app has `?2004`
  on) followed by Enter, or hold Enter until the text has been echoed.

### F2 MAJOR: scrolled up while Codex streams, the view jumps ~26 rows on its own
- Steps: ask Codex for 250 numbered lines; while they stream, drag the terminal down 300 pt (scroll up) and let go.
- Expected: the rows under the finger stay put until the person scrolls or taps the jump button.
- Actual: the view settles with row 46 at the top and holds it for ~1.8 s, then jumps to row 72 by itself
  (still not the bottom) while lines keep arriving; it then holds there.
- Evidence: `artifacts/frames/s3c-yank-5fps-f26-f49.jpg` (5 fps strip, 0.2 s per tile: following 66/74/79,
  drag 76..47, held 46 x9, jump to 72), per-frame `artifacts/frames/s3c-long-stream/` (f047 is the jump),
  `artifacts/video/s3c-long-stream.mp4` (64-76 s of the recording). Load 10.4 (1-min).
- Suspected area: `CmuxMobileTerminal/Session/TerminalRowShift.swift` / `TerminalFollowPolicy.swift` /
  `TerminalDocumentLayout.swift`: compensation when Codex's inline TUI commits rows into scrollback with a
  scroll region (bf186c56 path) while the viewport is detached from the bottom.
- Not a full yank-to-bottom: with Codex only showing `Working` (no streamed rows), a scrolled-up view held
  perfectly for 15 s and after completion (`artifacts/shots/s3b-scrolled-during-stream.jpg`, `s3b-after-done.jpg`).

### F3 MINOR: the jump-to-bottom button covers the last terminal rows' text
- `artifacts/shots/s3b-scrolled-during-stream.jpg`: the round button at x 346-386 hides the end of
  `"""Print readable multiplication tables fro…`. Consider insetting it into the composer gap or fading text under it.

### F4 MAJOR (intermittent, 1/4): the terminal goes blank when switching from a multi-line draft to direct typing
- Steps: keyboard up with the composer focused; type a 4-line draft (`one two ... seventeen`); tap the terminal
  (direct typing) with the draft still in the composer.
- Expected: Codex's rows stay visible above the (taller) composer.
- Actual: the whole terminal area above the composer is black; still black 3 s later; hiding the keyboard
  brings the content back. Three more attempts by the same path did not reproduce it.
- Evidence: `artifacts/shots/s4-lastrow-direct-typing-with-draft.jpg`, `artifacts/shots/s4-direct-with-draft-3s.jpg`,
  `artifacts/shots/s4-direct-with-draft-kbdown.jpg`; non-repro tries `artifacts/shots/s4c-try0..2.jpg`. Load ~6.
- Suspected area: `CmuxMobileTerminal/Screen/TerminalViewController.swift` / `TerminalDocumentLayout.swift`: a composer
  height change and a first-responder change (composer -> surface) in the same layout pass leave the viewport
  offset past the document end (or the Metal layer unredrawn) until the next keyboard frame change.

### F5 MAJOR: the joystick is uncontrollable in Codex's menus (wraps the list)
- Steps: `/model` (8 entries, wrapping). Drag the joystick knob down 30 pt and hold 1.2 s; then up 30 pt; down 20; down 60.
- Expected: a short hold moves one or a few rows; a person can stop on the row they want.
- Actual: selection after each: 2 -> 2 -> 2 -> 6 -> 5. Past 24 pt the joystick repeats every 30 ms (~33 arrows/s),
  so a 1.2 s hold sends ~40 arrows and lands on an arbitrary row (40 mod 8 = 0 looks like "nothing happened").
  Now that the thumb follows the finger past the circle (d7bf4d01), any drag past the 16 pt rim is already in the
  fastest gear. Horizontal cursor moves in a text line are fine (left 40 pt: column 10 -> 2).
- Evidence: `artifacts/shots/s5b-joystick-down30.jpg` .. `-down60.jpg`, `artifacts/shots/s5-model-menu.jpg`,
  video `codexqa-raw/s5b-joystick-vertical.mp4` (not committed). Mac selection read with `terminal screen read`.
- Suspected area: `CmuxMobileTerminal/KeyBar/Joystick.swift` gear table (8-16 pt 160 ms, 16-24 pt 80 ms, >24 pt 30 ms):
  scale the gears to the new 1.5x travel, start with one step on crossing the dead zone, and cap vertical repeat.

### F6 MINOR: dragging the joystick down hides the thumb under the keyboard
- `artifacts/shots/s5b-joystick-down30.jpg` (thumb cut by the keyboard's top edge), `-down60.jpg` (thumb invisible).
  Up and sideways it stays visible (`-up30.jpg`). The overlay is above the key bar but under the keyboard window.

### F7 MINOR (needs confirmation): one frame with the composer drawn twice while the keyboard hides
- 10 fps strip of the key-bar Hide Keyboard during streaming: one frame shows two composers (y ~322 and ~370) and
  a half keyboard (`codexqa-raw/s4-keyboard-during-stream.mp4` at 53.2 s). Could be capture tearing; check with
  Instruments or a 60 fps capture.

### F8 MAJOR: after switching back to the Codex tab, the last row sits half under the composer for seconds
- Steps: Codex working (`Working (48s ...)`); Tabs -> New Browser Tab -> Tabs -> tap the codex card.
- Expected: Codex's status row (`GPT-6-Astra max · ...`) rests above the composer as before the switch.
- Actual: the terminal comes back in 1.7 s, but the status row's lower half is under the composer card in every
  frame for at least 3.5 s (end of that recording); by 8 s it is fully visible again. This is the user's
  "row hidden under the composer", reproduced through a tab switch (keyboard down).
- Evidence: `artifacts/frames/s6-lastrow-hidden-after-tab-switch-4fps.jpg` (4 fps bottom crops, 47 s -> 53 s of
  Codex's timer), `artifacts/frames/s6-lastrow-2.5s-vs-8s.jpg`, `artifacts/shots/s6-back-to-codex-0..5.jpg`.
  Returning from Workspaces, foreground after 20 s in the background and a cold relaunch did NOT show it
  (`artifacts/shots/s6-return-*.jpg`, `s6-fg-*.jpg`, `s6-relaunch-*.jpg`).
- Suspected area: the warm-tab path (`CmuxMobileTerminal/Session/TerminalWarmSet.swift`, `TerminalHeldFrame.swift`):
  the re-shown page keeps the bottom inset/document height measured before the composer's final frame
  (or before Codex's next redraw) and only corrects on the next row change.

### F9 MAJOR: closing the Codex tab from the grid detaches a running Codex with no confirmation or undo
- Steps: Codex working (and holding a background terminal). Tabs -> the card's x.
- Expected: a confirmation that a program is running (or at least an Undo toast), since the close is one small tap.
- Actual: the card disappears at once; no prompt, no toast. On the Mac the Codex terminal keeps running with no
  tab (`tab_ids: []`, still `running` 2 min later); the phone has no way back to it, and the CLI says a tab-less
  terminal ends after the reap grace period.
- Evidence: `artifacts/shots/s6c-close-codex-0..4.jpg`; Mac `terminal list`: `term_cf4c6e41... running tab_ids []` at 12:16, 12:18 and 12:21 (5 min after the close).
- Suspected area: `CmuxMobileWorkspaces/WorkspaceTabsSource.swift` `close(_:)` (optimistic close, undone only when the
  Mac refuses); the tab's program state (`activity.state = in_use`) is available from the Mac.

### F10 MINOR: largest text size: the composer does not relayout on a live Dynamic Type change
- Steps: Settings text size -> AX XXXL while a terminal tab is open (`simctl ui content_size`).
- Actual: the placeholder grows but the card does not: `Send to azi…` is clipped (keyboard down) and drawn over
  the card's top edge (keyboard up, direct typing `Typing int…`). After the next trait change (appearance) the
  card grows correctly. The key bar does not scale (fine); the terminal grid is unaffected.
- Evidence: `artifacts/shots/s7-dark-axxxl-kbdown.jpg`, `s7-dark-axxxl-composer.jpg`, `s7-dark-axxxl-direct.jpg`,
  then `s7-light-axxxl.jpg` (correct).
- Suspected area: `CmuxMobileTerminal/Composer/ComposerTextView.swift` (UITextView height cache not invalidated on
  `UIContentSizeCategory.didChangeNotification` / `adjustsFontForContentSizeCategory`).

### F11 MINOR: cold relaunch flashes the white launch screen before the dark terminal
- ~1.3 s white screen with the chevron, then the dark held frame of the Codex tab (`artifacts/frames` n/a;
  video `codexqa-raw/s6b-nav-bg-relaunch.mp4` last 20 s). A dark launch background (or following the restored
  tab's appearance) avoids the flash. Reattach itself is good: input-ready 2.6 s after launch, with a small
  `Connecting to Aziz's MacBook Pro` badge over the held frame for ~0.3 s.

### F12 MINOR: New Terminal in a workspace opens in `~`, not the workspace's folder
- The `codexqa` workspace was created with `--cwd ~/cmux-next-ios-e2e/codexqa-proj`; Tabs -> + -> New Terminal opened
  `term_fe63...` in `/Users/azizalbahar`, so `codex` there would start in the wrong folder. (Could be Mac-side.)

### F13 MINOR: a new browser tab shows a debug stats overlay in the Demo build
- `phone 14:09.670 · 1 fps · 2 kbps · 804×1,444 · latency 257 ms · decode 13.0 ms` on an about:blank page
  (`artifacts/shots/s6-browser-new.jpg`). Fine if DEBUG-only; confirm it is compiled out of TestFlight.

### F14 MINOR: the key bar's Paste raises iOS's "Allow Paste" prompt for each new clipboard
- Key bar Paste in direct typing showed the system `Don't Allow Paste / Allow Paste` sheet mid-flow
  (`artifacts/shots/s2b-after-paste-key.jpg`). After Allow, the 3-line text reached Codex as one bracketed
  paste and stayed a draft until Return (correct). A `UIPasteControl` key (or the keyboard's own paste) avoids the prompt.

## Works well (no disruption seen)
- Codex startup, the folder-trust menu (arrow highlight, Enter on the soft keyboard), Codex's main screen
  and status row all render cleanly above the composer, keyboard up (`artifacts/sheets/s1-codex-start.jpg`,
  `artifacts/shots/s1b-codex-main.jpg`).
- Direct typing a prompt + return streams Codex's reply without flicker; the status row rests ~8 pt above the
  composer (`artifacts/shots/s2-reply.jpg`).
- Jump to bottom returns to the live end (`artifacts/shots/s3c-jumped.jpg`).
- Scrollback reaches the session start in 3 flicks after ~400 rows of Codex history (bf186c56 verified). The first
  row matches the Mac's own history (Codex's header; Codex erased the shell lines above it on the Mac too):
  `artifacts/shots/s3d-top.jpg`.
- Last row above the composer: keyboard down, composer focused, 3-line draft: Codex's status row ends ~9 pt above
  the composer card (`artifacts/shots/s4-lastrow-*.jpg`); with a photo in the attachment strip it ends ~17 pt
  above the card (`artifacts/shots/s4d-attachment-strip.jpg`).
- Keyboard hide/show via the key bar and the composer during streaming keeps the bottom rows anchored
  (`artifacts/sheets/s4-keyboard-during-stream.jpg`).
- Key bar ^C clears Codex's input; `/` opens Codex's command popup; key bar Down moves its selection; Esc closes it
  (`artifacts/shots/s5-*.jpg`). The joystick thumb now escapes the circle (`s5b-joystick-up30.jpg`).
- Tab grid -> + -> New Browser Tab / New Terminal / back to the Codex card: the Codex tab comes back live in 1.7 s
  with its full content (aside from F8). Back to Workspaces and reopening: 2.8 s, rows in place. Background 20 s
  and foreground: in place, no reconnect banner. Cold relaunch mid-Codex: restores the Codex tab, input-ready in 2.6 s.
- Dark/light switch: the terminal keeps its dark theme; chrome follows; no flash (`artifacts/shots/s7-*.jpg`).
- Toasts: the only toast seen in this pass was the small `Connecting to …` badge on relaunch (~0.3 s), which
  did not cover terminal rows the person was reading.

## Rig notes
- The `origin/feat-cnx-ios-mactry` fleet build (job 2f98c7fc4d02124e3beb58c2, Linux-pool placement) has no
  `cmux-mobile-host` in `Contents/Resources/bin` (the bundle phase is cache-only and found no cache). The rig copy got
  the mactry `cmux-mobile-host` from the user's `20261014-9c0201d569-mac-prod` build (same branch; the app passes it the
  dev Worker URL).
- mactry asks the person to Allow each phone on the Mac (sheet on a visible window, or Settings > Mobile,
  gesture-only). The hidden rig cannot click it; `qa.py` `rig_pair()` writes the rig's own
  `paired-devices.json` from the phone's public keys that a `cmux-mobile-host` stdout shim captured
  (`CMUX_NEXT_MOBILE_HOST_BIN` via `open --env`). The rig needs a supported approval path for future runs.
- Mac-side, outside terminal tabs: re-signing the rig bundle (new ad-hoc cdhash) made the app's own
  `MobileHostMacIdentityStore.keychainRead()` block the main thread on a Keychain access prompt during
  `IPhoneHostService.reconcile()`; the DEBUG `MainThreadWatchdog` then killed the app
  (`cmux DEV-2026-10-14-114143.ips`). Keychain reads belong off the main actor.

## Not exercised
- Rotation: the app is portrait-only (`UISupportedInterfaceOrientations` = Portrait).
- A Codex tool-approval prompt: the user's Codex config runs in YOLO mode, so no approval appeared; Codex's
  folder-trust menu and `/model` picker stood in for arrow/Enter/Esc menus. Not changed, to keep the user's config.
- Toast intrusiveness in general: no error/refusal toast fired in this pass (the close in F9 was accepted).
- iOS 27 runtime; a real device.

## How to rerun
`run.sh fetch-mac origin/feat-cnx-ios-mactry`, then `e2e.py --no-build --steps fresh_install,sign_in,choose_space
--latency none --keep`, inject `cmux-mobile-host` into the rig copy if the fleet build lacks it, `qa.rig_launch()` /
`qa.rig_pair(names=[<simulator name>])` (the DEBUG pairing seed; no relaunch), then drive with `qa.py` (`ctx()`, `rec_start`/`rec_stop`, `sheet`, `frames`).
Full-size recordings stay in `~/cmux-next-ios-e2e/codexqa-raw/` (not committed).
