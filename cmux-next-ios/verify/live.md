# Live data: verification

Branch `feat-cnx-ios-live`, 2026-10-12. New module `CmuxMobileLive`. The shell edits
are `ShellModel.swift`, `RootView.swift`, `Screens.swift` and `DemoDriver.swift`.
Evidence is git-ignored, in `verify/evidence/2026-10-12/live/`.

## What was built

`CmuxMobileLive` replaces the mocks once the app is signed in for real and has a
service URL (`CMUX_MOBILE_API_BASE`, or the dev Worker in DEBUG). Mock auth
(`CMUX_MOBILE_MOCK_AUTH=1`) is unchanged.

- **Teams and devices** (`LiveCoordinator`, `LiveAPI`, `DeviceIdentity`)
  - The phone registers with `POST /v1/devices` (`kind: phone`) in the active
    team.
  - With no Stack teams, the active team is the personal space
    `personal-<userId>`, shown in the sidebar as "Personal".
  - Macs come from `GET /v1/teams/:id/macs`. Team colors and emoji load with
    `GET /prefs`; the team editor saves them with `PUT /prefs`.
  - Invite asks for an email and calls `POST /invites {email}`. The personal
    space shows a toast instead.
  - A 401 refreshes the Stack token once and retries.
- **Two device ids.** Device ids are stored in the Keychain: `link` for
  dialing and `presence` for the presence socket.
  - The backend keeps one signaling socket per device, and a newer socket
    closes the older one (close code 4000).
  - The Rust link's own socket carries the WireGuard relay. Sharing one id
    would cut the relay every time the presence listener reconnected.
- **Presence** (`PresenceListener`): a `URLSessionWebSocketTask` on the team's
  signal socket.
  - The `hello` and `presence` frames update the sidebar dots and the
    Workspaces Mac sections live.
  - While the socket is down, it polls `GET /macs` and reconnects with
    backoff.
- **Link** (`LinkMachine`, `LinkController`)
  - `LinkMachine` is a pure state machine with phases idle, Mac offline,
    connecting, connected (path and RTT) and waiting (reason and retry).
  - Every dial and timer carries a generation number, so late results from an
    abandoned dial are ignored.
  - `LinkController` runs it on an injected clock:
    - It dials through `FFIMacLinkDialer` with the Settings transport, and a
      Settings change redials live.
    - It backs off 1, 2, 4, 8, 15 and 30 s.
    - It pings every 15 s with an 8 s timeout.
    - On foreground, it probes a live link or redials a waiting one.
  - The Mac's section header shows the status line, for example "Connected ·
    WireGuard relay · 27 ms".
  - The SPEC 7.4 banner shows these states:
    - "Connecting to <Mac> over …" on the first dial.
    - "Reconnecting to <Mac>…" after 1.5 s down.
    - "Can't reach <Mac> over WebRTC" while waiting to retry.
    - "<Mac> is offline".
    - "Connected" for 1.5 s.
- **Workspaces** (`WorkspaceSync`, `DaemonTree`) on the `daemon` channel:
  - Setup sends `set-client-info` (capabilities `conversation-tabs-v1` and
    `agent-session-tabs-v1`), then `identify`, `subscribe {tree_events:
    deltas}`, `list-agents` and `list-workspaces`.
  - Every tree delta, `tree-changed`, `title-changed` or `agent-changed`
    re-lists the tree, coalesced to one list in flight. `overflow`
    re-subscribes.
  - Agent tabs are `kind: conversation` with `conversation.agent_session`.
    The tab id is `s<surface>`, and the binding gives the acpmux session.
- **Agent chat** (`AcpmuxHub`, `AcpmuxSessionSource`, `AcpmuxRecords`) on the
  `acpmux` channel:
  - Setup runs `initialize`, then `_acpmux/watch`.
  - Each chat calls `_acpmux/attach {eventStream: true, kinds: [transcript]}`,
    pages history back with `_acpmux/events beforeSeq` (up to 2000 records),
    and then streams `_acpmux/event`.
  - The chat sends `session/prompt`, `session/cancel`,
    `_acpmux/permission_respond` (with harness-shaped `answers` for
    questions), and set model, mode or config.
  - After a link drop, a chat re-attaches from its last seq.
  - A refused call shows over the composer (`AgentChatStore.clientError`).
- **Feed** (`LiveFeed`): it builds items from `_acpmux/permission_pending`,
  from `session_changed` turn results, and from asks still open when the
  watch starts (read with `_acpmux/events`).
  - Inline answers go back through `FeedStore.actions` to the hub.
  - A refusal reverts the card and shows the reason under it. Each answer
    carries an attempt token, so a late refusal never overwrites a newer
    answer.
- **Chief**: on each link, `conversation-list` is probed on a `daemon` channel.
  If the Mac answers, `ChiefSession.shared` switches to `ChiefDaemonBackend`;
  otherwise the mock stays.
- **Terminal**: there is a `TODO(CmuxMobileTerminal)` seam in
  `LiveCoordinator.linkChanged`. `CmuxMobileTerminal` does not exist on this branch
  yet.

## The Mac under test

`mini-cmuxs-mac-mini-2`, user-local under `~/cmux-next-ios-e2e` only.

- Built from this tree with cargo: `cmux-tui` and `acpmux` (release) in
  `target-tui`, and `cmux-mobile-host`.
- `cmux-tui daemon start --session mobile --socket ~/cmux-next-ios-e2e/live/sock/cmuxMobile.sock`
  ran with `HOME` and the XDG directories pointed into `live/home`.
- `acpmux daemon run` used `ACPMUX_HOME=live/acpmux` and a loopback
  WebSocket.
  - The harness was the credit-free mock agent
    `crates/acpmux/tests/fake_agent.py`.
  - `webRoots` and `trust.json` covered `live/work` only.
- Seeding over the trusted local socket:
  - Workspaces `cmux-mobile-demo` (hammer, green) and `notes` (purple).
  - A `new-conversation-tab` bound to the acpmux session.
- `cmux-mobile-host` ran in the personal space with `CMUX_MOBILE_TUI_SOCKET_DIR`,
  `ACPMUX_HOME` and `CMUX_MOBILE_EXCLUDE_CGNAT=1`.
- Credentials: password sign-in with the DEBUG dev credential from
  `CmuxAuthRuntime`.
  - The tokens lived only in 0600 files; the refresh token reached the mini
    over ssh stdin.
  - The app got the credential as `SIMCTL_CHILD_*` variables, and nothing was
    printed.

## How it was verified

- **Unit tests** (Swift Testing, `CmuxMobileLiveTests`): 21 tests. Every CmuxMobileKit suite
  passes (54 tests) on `cmux-mobile-live-ios26`. They cover:
  - `LinkMachine`: dial, offline Mac, backoff, transport switch with a late
    result, drop, foreground probe, same and nil target.
  - `LinkController` over a mock dialer.
  - Signal frames and the error envelope.
  - The `DaemonTree` mapping (kinds, agent bindings, cwd, branch, color,
    unread, working, needs-you, kept activity times), error lines and event
    classification.
  - `WorkspaceSync` against a fake daemon behind `MockMacLink`: it re-lists on
    a delta.
  - acpmux records: chunks, mux records, permissions versus questions, and
    the Claude answer shape.
  - Hub, source and Feed against a fake acpmux, where an allow is refused as
    for a remote connection and a deny resolves the card.
  - A declined question becomes "cancelled".
- **End to end**: run in the headless simulator `cmux-mobile-live-ios26` (iOS 26.5,
  iPhone 17 Pro), dark mode. Simulator.app was never opened.
  - `verify/record-live.sh <udid> <dir> [seconds] [demo]` records with
    `simctl io recordVideo`, streams the app log, and takes a wall-clock still
    each second.
  - `-cmux-mobile-demo live` (DEBUG) drives the screens through their own code paths.
  - Before each run, the Mac's open asks were denied with the acpmux CLI.

| Check | Result | Evidence |
| --- | --- | --- |
| Signed in, personal space | Stack teams: 0, so the sidebar shows "Personal" with live dots (one online, one offline) | `run/key-chat-feed.png` (1st) |
| Mac online | "cmux mini 2 · Online", plus a stale smoke-test Mac offline ("Last seen 1h ago") | `run/key-transport.png` |
| Link | WireGuard over the Worker relay: connected about 4 to 7 s after launch, RTT 20 to 70 ms | `run/app.log` |
| Real workspaces | `cmux-mobile-demo` (2 tabs) and `notes` (main · 1 tab), with the daemon's colors and icons; "Needs you" while an ask is open | `run/key-transport.png` |
| Agent tab streams acpmux | Opens on the agent tab. History replays from attach, a prompt sent from the phone echoes back, and `ask:` shows the permission bar | `run/key-chat-feed.png` (2nd) |
| Feed: permission | The card shows Allow and Deny. Allow is refused (see below) and the card stays open with "Approve this on your Mac. A phone can only decline." **Deny reaches the Mac**: the demo pressed it at 23:27:01.34, and the Mac recorded `permission_decision {optionId:"no"}` at 23:27:01 (seq 83). The card then reads "Denied" | `run/key-chat-feed.png`, `run/mac-acpmux-records.txt` |
| Feed: question | The question card with A, B and Other appears. Answering is refused for a phone, and the card stays pending with the reason | `run/question-refused.png` |
| Transport switch | WireGuard to WebRTC: the first ICE attempt timed out after 26 s. The UI showed "Can't reach cmux mini 2 over WebRTC" and "Reconnecting over WebRTC…". The retry connected direct (2 ms RTT, same LAN). Switching back to WireGuard reconnected over the relay in 2.3 s | `run/key-transport.png`, `run/app.log` |
| Presence | `cmux-mobile-host` stopped: within 0.5 s the phone showed "cmux mini 2 is offline", with no dialing. Restarted: back online, and it redialed and connected in under 1 s | `presence/app.log`, `presence/live.mp4` |
| Foreground | Settings opened, then cmux reopened: the link was probed immediately (RTT logged off the 15 s heartbeat) | `presence/foreground.log` |
| Chief | `conversation-list is not available to a phone`: the hostd allowlist has no conversation commands. Chief stays on the mock, as designed | `run/app.log` |

## Findings

1. **A phone cannot allow or answer, only deny.** acpmux treats the
   `cmux-mobile-host` splice as a remote (`Web`) connection.
   - An allow, and every question answer (an answer is an allow with
     `answers`), needs the Mac app's person proof
     (`_meta.acpmux.personDecision`, an HMAC with the person key). Otherwise
     it fails with `permission.person_required`.
   - The app shows this gracefully, and deny and decline do reach the Mac.
   - Real allow and answer from the phone needs a protocol decision:
     - either `cmux-mobile-host` relays the app's signed decision,
     - or the phone holds a paired person key.
2. **WebRTC without TURN fails intermittently.** On this LAN it sometimes
   connects direct, and sometimes ICE times out once and the retry connects.
   The failure state and the retry show gracefully. A distant phone still
   needs TURN.
3. **The first dial can be refused with 401** right after the device is
   registered, or when a token cached at launch has expired. The next dial
   now refreshes the token, and HTTP calls retry once on a 401.
4. **The Feed tab crashed on open.** It read `@Environment(AppStore.self)`,
   which nobody provided (a merge regression between the shell and chat
   branches). `ShellView` now provides it.
5. **The agent transcript hung at 100 % CPU** in a SwiftUI scroll-position
   feedback loop (`ScrollToScrollStateRequest` writing
   `AgentChatSurface.position`). It happened once with live data. Writes that
   change nothing are now dropped, and four later runs did not hang.
6. **Conversation tabs carry the title `about:blank`.** It is replaced by the
   agent name.
7. **Chief over the link** needs `conversation-*` on the `cmux-mobile-host`
   allowlist, plus a trust decision (PROTOCOL.md).

## Known gaps

- No terminal over the link: waiting for `CmuxMobileTerminal`'s `TerminalSession`.
- New agent chats (tabs with no session yet) show "This chat hasn't started on
  the Mac yet". Starting one needs `session/new` with a `webRoots` cwd, and is
  not wired.
- The Mac section header's More menu (Reconnect, Unpair) is still inert.
  Selecting another Mac is `LiveCoordinator.select(macID:)`, with no UI yet.
- Workspace activity times are first-seen times; the daemon has no activity
  timestamp per workspace.
- Light mode and iOS 27 were not recorded for this pass.
