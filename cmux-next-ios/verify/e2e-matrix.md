# E2E matrix: the production Mac-to-phone journey

Branch `feat-cnx-ios-e2erig`, 2026-10-13 (overnight). Rig: `verify/e2e/run.sh`.
Evidence (git-ignored): `verify/evidence/2026-10-13/e2e/<run>/` (`results.json`,
`run.log`, `shots/`, `latency/*.mp4`, `hang-*.sample.txt`) and
`verify/evidence/2026-10-13/e2e/debug-runs/` (the runs that found the bugs below).

## Rig

| Part | What ran |
| --- | --- |
| Mac | A REAL cmux-next dev build: fleet job `3e82e412dcf9e9b472534842`, tag `cmux-mobile-e2e-210e55d9`, from `origin/feat-cnx-ios-machost` `210e55d9166c` (it already contains `origin/feat-cnx-ios` `99a50c71`). Bundled `cmux-mobile-host`, real daemon and acpmux; no standalone helpers, stubs or mocks. |
| Mac isolation | Bundle `com.cmuxterm.app.debug.cmuxMobile.e2e.210e55d9` (own Keychain items, preferences, Application Support, daemon session, control socket `/tmp/cmux-debug-cmux-mobile-e2e-210e55d9.sock`, Chief home). Settings: `CMUX_NEXT_CONFIG_FILE=~/cmux-next-ios-e2e/<tag>/config/cmux-next.json` in the copy's `LSEnvironment` (`CmuxConfigFile.overrideKey`; an override is never seeded from the user's files). The user's "cmux NEXT mobile", cmux NEXT and NIGHTLY were not touched. |
| Mac launch | `open -g -j -n` (background, hidden, never activated). No window appeared on screen (checked with CGWindowList each run). Quit at the end with `NSRunningApplication.terminate()` of that pid only. |
| Allow iPhone Connections | Set the documented person path for a test instance: `mobile.allowIPhoneConnections: true` written into the instance's own `cmux-next.json` before launch (the key Settings > Mobile writes; `cmux settings get` confirms it). |
| Sign-in | Mac: `CMUX_AUTH_CREDENTIALS_FILE` (a 0600 file under `~/cmux-next-ios-e2e/<tag>/secrets/`, read by `DogfoodCredentials`, DEBUG builds only) holding the DEBUG dev credential of `CmuxAuthRuntime`, extracted from source at run time and never printed. Phone: the same account through the real Welcome UI, email "42". |
| Phone | One headless iPhone 17 Pro simulator `cmux-mobile-e2e2-ios26` (iOS 26.5), then `cmux-mobile-e2e2-ios27` (iOS 27.0); deleted after each pass. Simulator.app never opened. The iOS app is the Demo configuration (-O, DEBUG developer surface) of `feat-cnx-ios` `99a50c71`, built locally with `-jobs 4`. |
| Input | Real HID touches through AXe. Text only through taps on the software keyboard's keys (never `axe type`, which makes iOS assume a hardware keyboard). System sheets and the photo picker that the accessibility tree does not show are read with Vision OCR (`verify/e2e/ocr.swift`). |
| Mac-side checks | The tagged app's own `cmux` CLI on its socket: `workspace list/create`, `tab create/rename`, `terminal screen read`, `terminal write`. |
| Latency | Measured from the simulator's own screen recording (`simctl io recordVideo`, up to 60 fps, per-frame timestamps). Keystroke echo: from the frame where the tapped key lights up to the frame where the terminal line changes (both ends in the video). Others: host time of the launch or tap mapped into the video, to the frame after which the watched region settles. |

Load caveat: other agents ran 4 to 5 more simulators and fleet clients on this
Mac all night (load average 150 to 210). Timings include that contention.

## Results (baseline: 2026-10-13, 99a50c71 + 210e55d9)

<!-- matrix:begin -->
Baseline: iOS `feat-cnx-ios` `99a50c71` (Demo) and Mac `feat-cnx-ios-machost` `210e55d9`. The full pass ran
first; the rig's `settings_find` helper was lost in that pass (transport, relay-only, sign-out, background and
Mac-restart failed on the rig, not the app), so those steps and the keystroke metrics were rerun in a second
pass on a fresh simulator. Keystroke echo is the time from the frame where the tapped key lights up to the
frame where the terminal line changes; at 60 fps a 0 ms median means the echo landed in the same frame (the Mac
is on the same host). Under flood here means a 100 Hz top-row writer, after the unthrottled flood hung the app
(finding 5).

### iOS-26-5 (cmux-mobile-e2e2-ios26), run 232608-ios26

iOS `c723376d77` (Demo); Mac `cmux DEV cmux-mobile-e2e-210e55d9.app` (origin/feat-cnx-ios-machost 210e55d9166c45830c0a315de6021a8898f2b349 (contains origin/feat-cnx-ios 99a50c71); fleet job 3e82e412dcf9e9b472534842, tag cmux-mobile-e2e-210e55d9). Summary: {'pass': 13, 'fail': 9, 'blocked': 2}. Evidence: `evidence/2026-10-13/e2e/232608-ios26/`.

| Step | Result | Time | Notes | Evidence | Owner |
| --- | --- | --- | --- | --- | --- |
| Fresh install and Welcome | Pass | 5.74 s | Welcome in 1.3 s: ['Your Macs, in your pocket.', 'Continue with Apple', 'apple.logo'] | `shots/01-fresh_install.png` |  |
| Sign in (dev account, email 42) | Pass | 18.09 s | signed in with the DEBUG dev credential (email 42) in 3.2 s | `shots/02-sign_in.png` |  |
| Choose team / personal, setup steps | Pass | 7.8 s | team: Not now (personal space); connect step: Aziz’s MacBook Pro is online; notifications: Not now | `shots/03-choose_space.png` |  |
| Mac discovered, no false 'No workspaces' | Pass | 7.83 s | Aziz’s MacBook Pro [Online] -> 'Connected · WebRTC direct · 0 ms' in 2.2 s | `shots/04-mac_discovered.png` |  |
| Workspaces list filtered by Mac matches the Mac | Pass | 1.17 s | 3 rows match the Mac (Home, workspace-1, e2e-232656) | `shots/05-workspace_list.png` |  |
| Create workspace (instant) | Pass | 16.4 s | 'New Workspace' on the Mac in 5.21 s; phone showed its terminal in 5.19 s (closed afterwards) | `shots/06-create_workspace.png` |  |
| Open workspace | Pass | 6.78 s | opened e2e-232656 on a terminal in 3.92 s; toolbar ['~', 'e2e-t1, ~'] | `shots/07-open_workspace.png` |  |
| Last-tab restore and tab grid | Pass | 91.83 s | reopened on the last tab (e2e-t2); grid switch back to e2e-t1 | `shots/08-last_tab_restore.png` |  |
| Terminal: direct typing (soft keyboard) | Pass | 15.67 s | typed 'echo d64949' + return on the software keyboard; the Mac ran it | `shots/09-term_direct.png` |  |
| Terminal: composer | Pass | 21.27 s | composer sent 'echo c76014' | `shots/10-term_composer.png` |  |
| Terminal: ^C, arrows, joystick | Pass | 219.36 s | ^C interrupted sleep; Up Arrow recalled the last command; Left Arrow moved the cursor (abd -> abcd); joystick moved the cursor 10->2 | `shots/11-term_keys.png` |  |
| Terminal: vim and top TUI | Pass | 108.06 s | vim wrote /tmp/cmux-mobile-e2e-232656.txt; top ran and quit; shell responsive after (htop not installed) | `shots/12-term_tui.png` |  |
| Terminal: scrollback | Pass | 13.87 s | scrolled back through 400 lines; jump-to-bottom tapped | `shots/13-term_scrollback.png` |  |
| Terminal: Files and Links preview | **Fail** | 36.62 s | the Preview of cmux-mobile-e2e-232656-sample.md stayed blank for 10 s (the Mac file has text); Source view is blank too | `shots/14-files_links.png` | termlive |
| Terminal: image upload | **Fail** | 18.81 s | the phone typed /Users/azizalbahar/.mobile/uploads/IMG_1000.jpeg into the shell, but no such file exists on the Mac (upload never happened); shell said: ['', '\uf015 ~', '❯'] | `shots/15-image_upload.png` | termlive |
| Agent chat (stream, tools, approvals, question, attachments, diff, artifacts) | Blocked | 0.0 s | no credit-free REAL harness on this Mac: no local model server (Ollama/LM Studio not installed) and cmux-next has no built-in echo harness; Claude/Codex would make paid model calls. Streaming, tool calls, Allow/Deny (Face ID), question answer, attachments, diff viewer and artifacts not run. | `shots/16-agent_chat.png` | approvals |
| Feed events and inline answer | Blocked | 4.85 s | Feed events come from agent asks; no credit-free harness (see agent_chat). Feed opened: ['Personal', '+16', 'Invite to team', 'All'] | `shots/17-feed.png` | approvals |
| Chief: real Mac conversation, send/receive, model | **Fail** | 35.93 s | Chief never loaded: the conversation spinner (conversation.initialLoading) was still up after 25 s; no model picker on the screen; Mac CLI `cmux chief engine`: cmux: this needs a newer cmux daemon (the chief.* operations); use the engine bar in Home for now | `shots/18-chief.png` | chieflive |
| Transport WebRTC <-> WireGuard | **Fail** | 2.19 s | 'Journey' object has no attribute 'settings_find' | `shots/19-transport.png` | fastconn |
| Relay only | **Fail** | 2.32 s | 'Journey' object has no attribute 'settings_find' | `shots/20-relay_only.png` | fastconn |
| Sign out and back in | **Fail** | 6.86 s | 'Journey' object has no attribute 'settings_find' | `shots/21-sign_out_in.png` | prodinfra |
| Background 45 s / foreground reconnect | **Fail** | 43.36 s | could not get back to the Workspaces list | `shots/22-background.png` | fastconn |
| Mac app quit / relaunch, reconnect | **Fail** | 42.28 s | could not get back to the Workspaces list | `shots/23-mac_restart.png` | machost |
| Device removal | **Fail** | 8.66 s | no way to remove a device: Paired Macs has no Remove/Forget action, and the Mac's removal is not revocation (production-audit.md: no DELETE route); the Mac side has no CLI action for it | `shots/24-device_removal.png` | machost |

| Metric | n | Median | p95 | Target | Evidence |
| --- | --- | --- | --- | --- | --- |
| keystroke_echo_idle | 0 | - | - | 50 ms | no samples |
| keystroke_echo_flood | 0 | - | - | 50 ms | no samples |
| tab_switch | 20 | 961 ms | 1065 ms | - | `latency/tab_switch.mp4` |
| cold_connect_to_list | 19 | 6148 ms | 7877 ms | 1500 ms (**misses**) | `latency/cold_connect.mp4` |
| warm_reconnect | 20 | 2362 ms | 2457 ms | 1000 ms (**misses**) | `latency/warm_reconnect.mp4` |
| agent_first_token | 0 | - | - | - | no credit-free real harness (see agent_chat) |
| feed_answer_round_trip | 0 | - | - | - | no agent asks without a harness (see feed) |

### iOS-26-5 (cmux-mobile-e2e2-ios26), run 000840-ios26

iOS `c723376d77` (Demo); Mac `cmux DEV cmux-mobile-e2e-210e55d9.app` (origin/feat-cnx-ios-machost 210e55d9166c45830c0a315de6021a8898f2b349 (contains origin/feat-cnx-ios 99a50c71); fleet job 3e82e412dcf9e9b472534842, tag cmux-mobile-e2e-210e55d9). Summary: {'pass': 8, 'fail': 2, 'blocked': 0}. Evidence: `evidence/2026-10-14/e2e/000840-ios26/`.

| Step | Result | Time | Notes | Evidence | Owner |
| --- | --- | --- | --- | --- | --- |
| Fresh install and Welcome | Pass | 3.84 s | Welcome in 1.2 s: ['Your Macs, in your pocket.', 'Continue with Apple', 'apple.logo'] | `shots/01-fresh_install.png` |  |
| Sign in (dev account, email 42) | Pass | 8.18 s | signed in with the DEBUG dev credential (email 42) in 1.9 s | `shots/02-sign_in.png` |  |
| Choose team / personal, setup steps | Pass | 4.6 s | team: Not now (personal space); connect step: Aziz’s MacBook Pro is online; notifications: Not now | `shots/03-choose_space.png` |  |
| Mac discovered, no false 'No workspaces' | Pass | 5.09 s | Aziz’s MacBook Pro [Online] -> 'Connected · WebRTC direct · 0 ms' in 1.3 s | `shots/04-mac_discovered.png` |  |
| Transport WebRTC <-> WireGuard | Pass | 67.78 s | WireGuard Connected in 3.9 s, back to WebRTC in 3.7 s; terminal input worked on both | `shots/05-transport.png` |  |
| Relay only | Pass | 57.82 s | 'Connected · WebRTC TURN · 59 ms' in 5.0 s; terminal worked over the relay; toggled back off (value 0) | `shots/06-relay_only.png` |  |
| Sign out and back in | Pass | 23.51 s | signed out to Welcome, signed back in and relinked the rig Mac | `shots/07-sign_out_in.png` |  |
| Background 45 s / foreground reconnect | **Fail** | 57.22 s | APP HUNG (main thread busy, no accessibility, sample hang-1-background.sample.txt). no soft key for 'e'; have [] | `shots/08-background.png` | fastconn |
| Mac app quit / relaunch, reconnect | Pass | 58.97 s | offline shown 0.4 s after quit ('Aziz’s MacBook Pro is offline'); reconnected 2.6 s after cmux-mobile-host was back; terminal OK | `shots/09-mac_restart.png` |  |
| Device removal | **Fail** | 9.29 s | no way to remove a device: Paired Macs has no Remove/Forget action, and the Mac's removal is not revocation (production-audit.md: no DELETE route); the Mac side has no CLI action for it | `shots/10-device_removal.png` | machost |

App hangs (main thread busy, no accessibility; sampled, then relaunched):

- after `background`: main thread busy, no accessibility, CPU 100.2%, `hang-1-background.sample.txt`

| Metric | n | Median | p95 | Target | Evidence |
| --- | --- | --- | --- | --- | --- |
| keystroke_echo_idle | 20 | 0 ms | 20 ms | 50 ms (meets) | `latency/keystroke_echo_idle.mp4` |
| keystroke_echo_flood | 20 | 0 ms | 12 ms | 50 ms (meets) | `latency/keystroke_echo_flood.mp4` |
| agent_first_token | 0 | - | - | - | no credit-free real harness (see agent_chat) |
| feed_answer_round_trip | 0 | - | - | - | no agent asks without a harness (see feed) |


<!-- matrix:end -->

## Rerun on current builds (2026-10-14 00:54, iOS 26.5)

iOS `feat-cnx-ios` `05600628` merged into this branch (`245779ad`), Demo configuration. Mac: fleet job
`f9133c722640bee8bd62af2b`, tag `cmux-mobile-e2e-604fc689`, `origin/feat-cnx-ios-machost` `604fc6893acc` (includes PR
#20414's `038d0663` removal change and the `chief.*` operations). One full pass, cold launch x20 included.
No app hang occurred in this pass (the rig samples any). Evidence: `verify/evidence/2026-10-14/e2e/005437-ios26/`.

Rig corrections to the table below, checked against `cmux-mobile-host.log` and the Mac's files:
- **Transport: pass.** The phone switched to WireGuard (hostd: `link up kind=WireGuard path=Relay` 08:05:09Z) and back to
  WebRTC (`kind=WebRtc path=Direct` 08:05:55Z, 1 s after the phone closed the WireGuard link); terminal input worked
  on WireGuard. The "Fail" is the rig's OCR of the Filter menu reading only the Mac name. WireGuard went through the
  relay, not direct, on the same host.
- **Image upload: pass on the Mac side.** hostd: `upload saved size=1484524`; the file is
  `~/.cmux/attachments/phone-<id>/Photo 2026-10-14 at 01.04.28.jpeg`. The "list index out of range" is a rig bug
  (fixed in `journey.py`), so the path typed into the shell was not checked this pass.
- **Mac quit / relaunch**: the "offline shown 5.1 s" includes the rig's menu-reading overhead (about 3 s per read).

### iOS-26-5 (cmux-mobile-e2e2-ios26), run 005437-ios26

iOS `2b246fff9f` (Demo); Mac `cmux DEV cmux-mobile-e2e-604fc689.app` (origin/feat-cnx-ios-machost 604fc6893acca49b81b7cbf2763e4503ae94776f; fleet job f9133c722640bee8bd62af2b, tag cmux-mobile-e2e-604fc689). Summary: {'pass': 17, 'fail': 4, 'blocked': 3}. Evidence: `evidence/2026-10-14/e2e/005437-ios26/`.

| Step | Result | Time | Notes | Evidence | Owner |
| --- | --- | --- | --- | --- | --- |
| Fresh install and Welcome | Pass | 3.65 s | Welcome in 1.8 s: ['Your Macs, in your pocket.', 'Continue with Google', 'GoogleLogo'] | `shots/01-fresh_install.png` |  |
| Sign in (dev account, email 42) | Pass | 8.47 s | signed in with the DEBUG dev credential (email 42) in 2.1 s | `shots/02-sign_in.png` |  |
| Choose team / personal, setup steps | Pass | 5.7 s | space: Personal; connect step: Aziz’s MacBook Pro is online | `shots/03-choose_space.png` |  |
| Mac discovered, no false 'No workspaces' | Pass | 16.55 s | Filter > rig Mac: rows in 1.7 s; link 'Aziz's MacBook Pro Online • Connected • WebRTC direct • 0 ms' | `shots/04-mac_discovered.png` |  |
| Workspaces list filtered by Mac matches the Mac | Pass | 1.01 s | 3 rows match the Mac (Home, e2e-005451, workspace-1) | `shots/05-workspace_list.png` |  |
| Create workspace (instant) | Pass | 9.35 s | 'New Workspace' on the Mac in 2.84 s; phone showed its terminal in 2.83 s (closed afterwards) | `shots/06-create_workspace.png` |  |
| Open workspace | Pass | 2.36 s | opened e2e-005451 on a terminal in 1.14 s; toolbar ['~', 'e2e-t1, ~'] | `shots/07-open_workspace.png` |  |
| Last-tab restore and tab grid | Pass | 70.34 s | reopened on the last tab (e2e-t2); grid switch back to e2e-t1 | `shots/08-last_tab_restore.png` |  |
| Terminal: direct typing (soft keyboard) | Pass | 16.29 s | typed 'echo d88943' + return on the software keyboard; the Mac ran it | `shots/09-term_direct.png` |  |
| Terminal: composer | Pass | 21.34 s | composer sent 'echo c16402' | `shots/10-term_composer.png` |  |
| Terminal: ^C, arrows, joystick | Pass | 212.58 s | ^C interrupted sleep; Up Arrow recalled the last command; Left Arrow moved the cursor (abd -> abcd); joystick moved the cursor 10->2 | `shots/11-term_keys.png` |  |
| Terminal: vim and top TUI | Pass | 93.63 s | vim wrote /tmp/cmux-mobile-e2e-005451.txt; top ran and quit; shell responsive after (htop not installed) | `shots/12-term_tui.png` |  |
| Terminal: scrollback | Pass | 16.96 s | scrolled back through 400 lines; jump-to-bottom tapped | `shots/13-term_scrollback.png` |  |
| Terminal: Files and Links preview | **Fail** | 57.6 s | the Preview of cmux-mobile-e2e-005451-sample.md stayed blank for 10 s (the Mac file has text); Source view is blank too | `shots/14-files_links.png` | termlive |
| Terminal: image upload | **Fail** | 27.66 s | list index out of range | `shots/15-image_upload.png` | termlive |
| Agent chat (stream, tools, approvals, question, attachments, diff, artifacts) | Blocked | 0.0 s | no credit-free REAL harness on this Mac: no local model server (Ollama/LM Studio not installed) and cmux-next has no built-in echo harness; Claude/Codex would make paid model calls. Streaming, tool calls, Allow/Deny (Face ID), question answer, attachments, diff viewer and artifacts not run. | `shots/16-agent_chat.png` | approvals |
| Feed events and inline answer | Blocked | 5.79 s | Feed events come from agent asks; no credit-free harness (see agent_chat). Feed opened: ['Personal', '+17', 'Invite to team', 'All'] | `shots/17-feed.png` | approvals |
| Chief: real Mac conversation, send/receive, model | Blocked | 13.73 s | Chief loaded in 0.8 s; send/receive not run (a paid model call). Model controls: none; Mac engine: claude · default · medium | `shots/18-chief.png` | chieflive |
| Transport WebRTC <-> WireGuard | **Fail** | 83.47 s | WebRTC: link not Connected over WebRTC after 30 s ("Aziz's MacBook Pro") | `shots/19-transport.png` | fastconn |
| Relay only | Pass | 80.68 s | 'Aziz's MacBook Pro Online • Connected • WebRTC TURN • 46 ms' in 14.7 s; terminal worked over the relay; toggled back off (value 0) | `shots/20-relay_only.png` |  |
| Sign out and back in | Pass | 39.15 s | signed out to Welcome, signed back in and relinked the rig Mac | `shots/21-sign_out_in.png` |  |
| Background 45 s / foreground reconnect | Pass | 86.71 s | 45 s in background; Connected 4.92 s after foreground; terminal input reached the Mac | `shots/22-background.png` |  |
| Mac app quit / relaunch, reconnect | Pass | 95.85 s | offline shown 5.1 s after quit ('Aziz's MacBook Pro'); reconnected 4.8 s after cmux-mobile-host was back; terminal OK | `shots/23-mac_restart.png` |  |
| Device removal | **Fail** | 91.74 s | the removed rig Mac came back in the phone's Mac list within 30 s (cmux on it is still running) | `shots/24-device_removal.png` | machost |

| Metric | n | Median | p95 | Target | Evidence |
| --- | --- | --- | --- | --- | --- |
| keystroke_echo_idle | 20 | 15 ms | 32 ms | 50 ms (meets) | `latency/keystroke_echo_idle.mp4` |
| keystroke_echo_flood | 20 | 0 ms | 17 ms | 50 ms (meets) | `latency/keystroke_echo_flood.mp4` |
| tab_switch | 20 | 1173 ms | 1279 ms | - | `latency/tab_switch.mp4` |
| cold_connect_to_list | 20 | 4213 ms | 4456 ms | 1500 ms (**misses**) | `latency/cold_connect.mp4` |
| cold_link_up | 20 | 1162 ms | 1274 ms | 1500 ms (meets) | `latency/` |
| warm_reconnect | 20 | 0 ms | 0 ms | 1000 ms (meets) | `latency/` |
| agent_first_token | 0 | - | - | - | no credit-free real harness (see agent_chat) |
| feed_answer_round_trip | 0 | - | - | - | no agent asks without a harness (see feed) |


### Findings 1-12 on the current builds

| # | Finding | Now | Evidence (2026-10-14/e2e/005437-ios26/) |
| --- | --- | --- | --- |
| 1 | "No workspaces" during connecting on cold launch | **Fixed.** Cached rows show from the first frame after the splash in all 20 cold launches; no empty state | `latency/cold-connect-strip-2fps.png` |
| 2 | Chip choice does not move the link | **Fixed / moot.** Chips are gone; Filter > Mac linked it with rows in 1.7 s and "Connected · WebRTC direct". Only one other Mac was online, so the two-online-Macs case was exercised less hard than in the baseline | `shots/04-mac_discovered.png` |
| 3 | Cold and warm connect slow | **Mostly fixed.** Phone link up on the Mac p95 1.27 s (target 1.5 s); warm: all 20 links survived 20 s in background (0 ms). The list region still settles 4.2 s after process start (splash plus layout), so "launch to settled list" misses 1.5 s | `latency/` |
| 4 | Main-thread hang in TabsScreen while typing | **Not reproduced** in this pass (0 hangs, same typing steps). Fix in progress; not proven gone | `results.json` `hangs: []` |
| 5 | Output flood freezes the app | **Improved.** Under the 100 Hz writer, echo p95 17 ms and no touch timed out; the unthrottled writer was not rerun | `latency/keystroke_echo_flood.mp4` |
| 6 | Image upload fake | **Fixed** (Mac received 1.48 MB in `~/.cmux/attachments/`) | `run.log`, `cmux-mobile-host.log` |
| 7 | Files and links preview blank | **Still failing.** Preview and Source stay blank. Root cause in `cmux-mobile-host.log`: the file channel is refused, `code="forbidden" reason="no workspace roots are shared"`; the phone shows a blank page instead of that error | `shots/14-files_links.png`, `files-preview-005451.png` |
| 8 | Chief never loads | **Fixed.** Chief opens in 0.8 s with the real Mac Chief history; the engine is `claude · default · medium`. No message sent (paid). A settings (sliders) button is in the header; the rig did not open the model picker | `shots/chief-005451.png` |
| 9 | New Workspace slow / blank browser page | **Partly.** Terminal on screen 2.8 s after the tap (Mac confirmed at the same time); the blank-browser case did not recur | `shots/06-create_workspace.png` |
| 10 | Terminal left scrolled up on a blank page | **Still failing.** After the Files and links step the terminal sits on a blank page with "Scroll to bottom" shown | `shots/15-image_upload.png` |
| 11 | No device removal | **Partly.** Settings > Paired Macs now has Remove (swipe, confirm dialog) and the row leaves the list, but the rig Mac (online, Allow iPhone Connections on) was back in the phone's Mac list within 30 s and the phone relinked to it (hostd `link up` 08:34:03Z). The dialog itself says an online Mac can add itself back | `shots/24-device_removal.png` |
| 12 | Key bar accessibility frames | **Not rechecked** (the rig avoids the pinned group) | - |

## Failures and owners (baseline)

<!-- findings:begin -->
Paths are relative to `verify/evidence/2026-10-13/e2e/`.

| # | Finding | Evidence | Owner |
| --- | --- | --- | --- |
| 1 | **"No workspaces" lie on every cold launch.** While the link is "Connecting to Aziz's MacBook Pro over WebRTC…", the list shows "No workspaces on Aziz's MacBook Pro. Aziz's MacBook Pro can't take new workspaces from this iPhone yet." for about 2 s, then the rows appear. Seen in every one of the 20 cold launches. | `232608-ios26/latency/cold-connect-strip-1fps.png` (1 frame/s), `cold_connect.mp4` | fastconn |
| 2 | **Choosing a Mac chip does not move the link.** With more than one online Mac on the account (the dev account had 3 to 5 online), the phone links the first online Mac. Tapping the rig Mac's chip only filters the list (`WorkspacesList.select` changes `MacFilter`; `LiveCoordinator.select(macID:)` is reached only from the chip's long-press Reconnect), so the list said "No workspaces on Aziz's MacBook Pro … can't take new workspaces" for an online Mac with 3 workspaces, indefinitely. Long-press > Reconnect fixed it in 3.4 s. Production users with two Macs hit this. | `debug-runs/dbg1/shots/04-mac_discovered.png`, `debug-runs/dbg2/results.json` | fastconn (with dataflow) |
| 3 | **Cold connect and warm reconnect miss their targets** (table above): cold launch to the Mac's list p95 7.9 s (target 1.5 s), foreground after 20 s in background to "Connected" p95 2.5 s (target 1 s). The load on this Mac inflates both; the "Connecting" phase alone is 2 to 3 s of each cold launch in the strip. | `232608-ios26/latency/` | fastconn |
| 4 | **Main-thread hang in the workspace screen.** Twice while typing into a workspace terminal (once in `term_keys`, once after foreground), the app went to 100% CPU with an empty accessibility tree and never recovered. The main thread loops in SwiftUI updates of `TabsScreen.body` / `TabsScreen.activeTab` / `WorkspaceTabsSource.activeTabID` / `AppStore.workspace(id:)` (`TabsView.swift:74,96`, `WorkspaceTabsSource.swift:23`). The rig sampled it, then relaunched. | `debug-runs/hang-tabsscreen-term_keys.txt`, `debug-runs/hang-1-background.sample.txt` | wsdesign (CmuxTabsKit host) |
| 5 | **Terminal output flood freezes the app.** A shell writing the top row about 100 times a second (`printf` + `sleep 0.01`) made every touch time out (`axe tap` waited 120 s); an unthrottled writer pegged the app at 100 to 140% CPU, still busy after the writer stopped. The main thread is in `TerminalViewController.surfacePresented()` / `updateDocument()` per output chunk (`TerminalViewController.swift:555,627-665`), fed by `DaemonTerminalSession.attach()`. No keystroke-echo number under flood could be taken. | `debug-runs/hang-flood.sample.txt`, `debug-runs/hang-flood100hz.sample.txt` | termlive |
| 6 | **Image upload is fake** (audit blocker 7, confirmed live). Picking a photo in the terminal composer and sending types `~/.mobile/uploads/IMG_1000.jpeg` into the shell; no file is ever written on the Mac (`zsh: no such file or directory`). Files and links then lists that nonexistent path twice (absolute and `~/`). | `debug-runs/att3.png`, `debug-runs/fl2.png`, step `image_upload` | termlive |
| 7 | **Files and links preview is blank.** The sheet lists a real Mac file (`/tmp/cmux-mobile-e2e-…-sample.md`), but its Preview and Source views stay empty (10 s), though the file has text. In list mode the sheet is also invisible to accessibility (VoiceOver cannot reach it; the rig reads it with OCR). | `debug-runs/fl3.png`, step `files_links` | termlive |
| 8 | **Chief never loads.** Home > Chief shows the conversation spinner (`conversation.initialLoading`) for more than 25 s, no messages and no model picker. On the Mac, `cmux chief engine` answers "this needs a newer cmux daemon (the chief.* operations)". Send/receive was not attempted (paid model). | `debug-runs/chief2.png`, step `chief` | chieflive |
| 9 | **New Workspace is not instant.** The phone shows the new terminal and the Mac lists the workspace 2.3 to 5.2 s after the tap. Twice in the debug runs the optimistic page instead became a blank browser tab ("Search or enter website", keyboard up) that the Mac never confirmed; its back button was hidden behind the address field, and only the edge swipe left it. | `debug-runs/c1.png`, `debug-runs/c2.png` | dataflow |
| 10 | **Terminal left scrolled up on a blank page.** After `clear` or a scrollback test the terminal sits scrolled up with the prompt off screen ("Scroll to bottom" shown) and typing does not bring the cursor back into view, so the user types blind. | `debug-runs/pk.png`, `232608-ios26/latency/keystroke_echo_idle.mp4` | termlive |
| 11 | **No device removal.** Neither the phone (Settings > Paired Macs: no Remove, Forget or swipe action) nor the Mac CLI can remove a device; the dev account now lists 21 Macs, most stale, several with the same name. Paired Macs also shows "Last seen 3h ago" for Macs whose chips say "Last seen 1 m ago". | step `device_removal` | machost |
| 12 | **Key bar accessibility frames lie.** Keys scrolled under the pinned esc/ctrl/alt keep frames there, so an accessibility activation of "Left Arrow" lands on ctrl (the rig first typed `^C` this way). | step `term_keys` (fixed in the rig by revealing keys right of the pinned group) | termlive |
<!-- findings:end -->

## Blocked (not failures, not passes)

- **Agent chat** (streaming, tool calls, permission Allow with Face ID and Deny, question answer, attachments, diff viewer, artifacts) and its latency (first token): no credit-free REAL harness exists on this Mac. No Ollama or LM Studio; cmux-next has no built-in echo or test harness; Claude and Codex would make paid model calls. The rig never fakes an agent. To unblock: install a local model server (Ollama) and point a cmux-next agent at it, then rerun `run.sh --steps agent_chat,feed`.
- **Feed** events and the inline-answer round trip: events come from agent asks, so they wait on the harness above.
- **Chief send/receive** and the model picker: not exercised (a paid model call). Chief loads on the current builds (finding 8).

## Rerun

```bash
cmux-next-ios/verify/e2e/run.sh fetch-mac origin/feat-cnx-ios-machost   # after Mac-side merges: fleet build, tag cmux-mobile-e2e-<sha8>
cmux-next-ios/verify/e2e/run.sh both                                   # iOS 26.5 then iOS 27, journey + latency
cmux-next-ios/verify/e2e/run.sh --steps term_keys,term_tui --latency none --keep   # a subset, keep the rig up
python3 cmux-next-ios/verify/e2e/matrix.py cmux-next-ios/verify/evidence/<date>/e2e/*/results.json
```
