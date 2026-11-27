# Workspaces and Chief: verification

Branch `feat-cnx-ios-ws`, 2026-10-12. New modules `CmuxMobileWorkspaces` and `CmuxMobileChief`.
Shell edits are limited to `Screens.swift` (Home and Workspaces stacks),
`DemoDriver.swift` (two demos) and `Package.swift`. Evidence is git-ignored, in
`verify/evidence/2026-10-12/ws/`.

## What was built

### Workspaces (`CmuxMobileWorkspaces`)

- **List** (SPEC 11.1). One plain section per Mac: a presence dot, the name, and
  "Online" or "Last seen 2h ago", with a trailing More menu (Pair Details,
  Reconnect, Unpair). Online Macs come first. Each 64 pt row shows the
  workspace icon in its color, an unread dot, the title, the branch in mono
  plus the tab count, a relative time ("1m", "3h"), and either a "Needs you"
  pill or a working spinner. The trailing capsule has New workspace (a sheet:
  Mac, directory, first tab) and More (sort by Recent or Name, Show Offline
  Macs). Loading, failure and empty states are unchanged.
- **Workspace screen**: CmuxTabsKit's `TabsView`, driven by
  `WorkspaceTabsSource`.
  - It opens on `AppStore.openingTab`, the last tab used on this device.
    Every activation is recorded (card tap, swipe, a new tab, closing the
    active tab). `TabMemory` persists the record in `UserDefaults`, so it
    survives a relaunch.
  - Agent tabs show the CmuxMobileAgentChat transcript as the page and the composer
    (or the permission bar) as TabsKit's accessory row. That row rides the
    toolbar and the keyboard. `AgentChatScreen` was split into
    `AgentChatTranscript`, `AgentChatBottomStack` and a shared
    `AgentChatSurface`; the pushed chat is unchanged.
  - Terminal tabs go through the `TerminalTabContent` protocol (page, card,
    optional accessory). `PlaceholderTerminalTabContent` stands in until
    CmuxMobileTerminal passes its own to `WorkspaceScreen(terminal:)`.
  - Browser tabs use a per-tab `WKWebView` with back, forward, reload,
    address editing and a snapshot card.
  - The page menu (tap the title capsule) has Changes, Copy Session ID,
    All Workspaces, Stop Agent and Close Tab. The (+) menu offers Claude,
    Codex, Terminal and Browser tabs.
  - Theme: `TabsKitTheme.mobile`. Pages are black, the grid uses a neutral
    gray wallpaper, and the accent is neutral. The accent is a mid gray in
    dark mode because TabsKit draws Done's checkmark in white.
- **Navigation decisions.** The workspace is pushed on the Workspaces stack
  with both the navigation bar and the root tab bar hidden. TabsKit's toolbar
  owns the bottom edge (SPEC 3.1, full-screen surfaces). There are four ways
  back to the list:
  1. The toolbar's back chevron. Agent and terminal tabs have no history,
     so back leaves the workspace. Browser tabs walk their page history
     first.
  2. The system left-edge swipe. SwiftUI disables it while the bar is
     hidden, so `InteractivePopEnabler` turns it back on.
  3. A glass back circle in the grid's top row, with the workspace name and
     "Mac · N tabs" in the middle. TabsKit's More button sits on the trailing
     side at the same height.
  4. "All Workspaces" in the page menu.

### Chief (`CmuxMobileChief`)

- **Home** (`ConversationsHome`) follows the Messages list. It has a large
  title, an always-visible search field and the drawer circle on the leading
  side. The trailing capsule has a filter (All, Unread, Needs You) and
  compose.
  - Chief is pinned in Messages' pinned grid as an 88 pt avatar with its name.
    A typing bubble or a preview bubble appears over the avatar when Chief is
    typing or has unread messages.
  - Agent conversations are Messages rows: an unread-dot gutter, a 45 pt
    monogram on the Contacts gradient, the name, the date (time, Yesterday,
    weekday, or date) and a chevron, and a two-line preview.
  - Rows have leading Unread and trailing Delete and Hide Alerts swipe
    actions, plus a context menu.
- **Chief conversation**: CmuxConversation's `ConversationViewController`,
  wrapped by `ChiefConversationScreen` over the app-wide
  `ChiefSession.shared` store. The service line reads "Chief / Runs your
  agents on your Macs" and the placeholder reads "Message Chief"; no
  "iMessage" or "Encrypted" text appears. The navigation bar and tab bar are
  hidden because the controller draws its own glass header and composer.
- **Backends**:
  - `ChiefMockBackend` is the default. It has a seeded history, read
    receipts and a typing indicator, and it tapbacks messages that thank or
    praise Chief. It replies based on the message, is idempotent on the
    client id, and supports edit and unsend.
  - `ChiefDaemonBackend` follows cmux-tui `local-conversations-v1` over a
    link's `daemon` channel through `DaemonClient`. It finds the Chief
    conversation with `conversation-list` or creates it with an idempotency
    key, then calls `subscribe` and `conversation-snapshot`. Older pages come
    from `conversation-history`. Sends, edits, retracts, tapbacks and read
    cursors are `conversation-op` calls, and typing uses
    `conversation-typing`. It maps the `conversation-changed` changes
    (message, message-updated, read-cursor, conversation) and the
    `conversation-typing` event. Chief's read cursor becomes Read receipts.
    A `rev` gap resyncs with `lagged:true`.
  - Swap backends with `ChiefSession.shared.use(try await
    ChiefDaemonBackend.open(link:))` once a Mac link exists.

## How it was verified

- `xcodegen generate` and a simulator build (`build/dd`), clean (no warnings in the new modules).
- Unit tests (Swift Testing), run with `xcodebuild test -scheme CmuxMobileKit-Package` on `cmux-mobile-ws-ios26`:
  25 passed. They cover:
  - `TabMemory`: the last tab survives a relaunch, a forgotten tab falls back
    to the first, closing a tab remembers its neighbor.
  - `WorkspaceTabsSource`: it opens on the last tab, records each
    activation, activates a neighbor on close, appends new tabs, maps tabs to
    the TabsKit chrome, and back leaves the workspace.
  - `RelativeStamp` and `MessagesStamp`.
  - `ChiefWire`: tapback names, parts, receipts and reactions.
  - `ChiefDaemonBackend` against a fake daemon behind `MockMacLink`: list,
    create, subscribe, snapshot, then send, a Read receipt, typing, Chief's
    reply, a tapback and history.
  - `ChiefMockBackend`: a reply with typing and a tapback, and idempotent
    sends.
- Recordings: own headless simulators `cmux-mobile-ws-ios26` (iOS 26.5) and `cmux-mobile-ws-ios27` (iOS 27.0),
  iPhone 17 Pro, dark mode, `CMUX_MOBILE_MOCK_AUTH=1`. Simulator.app was never opened.
  `verify/record-ws.sh <udid> <label>` records `-cmux-mobile-demo workspaces` and
  `-cmux-mobile-demo chief` and splits frames at 2 fps (more where noted).
  - The workspaces demo opens `cmux` on its last tab (the Claude chat) and
    types and sends a prompt; the mock streams a turn. It opens the grid,
    zooms into the terminal card, opens the grid again, zooms into the
    browser card, opens and closes the grid, and leaves. It reopens the
    workspace, which starts on the browser tab. The app is then terminated
    and relaunched with `-cmux-mobile-demo workspaces-reopen`, which opens the
    workspace on the browser tab again.
  - The chief demo starts on the Home list and opens Chief. It sends
    "thanks! what's the status?", which shows the Read receipt, Chief's
    heart tapback, the typing bubble and the reply. It double-taps Chief's
    reply and picks a thumbs-up from the tapback bar, sends "yes, allow it"
    and gets the reply, scrolls to the top (the start header shows the Chief
    service line) and back down, then goes back to the list.

| Evidence | What |
| --- | --- |
| `ios26/`, `ios27/` `workspaces-dark.mp4`, `chief-dark.mp4` | Recordings |
| `*/…-frames/`, `*/sheet-*.png` | Frame splits and contact sheets |
| `cmp-tabs-ios27.png` | Agent page, terminal page, TabsKit Demo page and grid |
| `cmp-grid-ios26.png` | Our grid next to the TabsKit Demo grid |
| `cmp-home-messages-ios26.png`, `cmp-home-messages-ios27.png` | Home next to the Messages app on the same simulator |
| `ref/messages-list-ios2{6,7}.png` | Messages app captures (`simctl launch com.apple.MobileSMS`) |

## Frame-by-frame findings and fixes

1. **The agent card did not match the page at the end of the zoom.** The live
   transcript shrank into the card, then the card showed the top of the first
   turn, which popped. `AgentChatPreview` now bottom-aligns the newest turns
   at their natural height, with the same bottom inset as the page (from the
   composer's measured top). At 8 to 12 fps the zoom out and in is now
   continuous on both OS versions.
2. **The pinned Chief avatar sat at the leading edge with a row chevron.** A
   `NavigationLink` inside an `HStack` with spacers made the link the row
   label. The pin is now a full-width link with the indicator hidden, and it
   is centered as in Messages.
3. **Monograms were plain gray.** They now use the Contacts gradient measured
   from the Messages capture.
4. **Search was hidden until pulled down.** It is now always visible
   (Messages shows it permanently).
5. **Recordings showed the "◀ Messages" back-to-app breadcrumb.** The
   Messages reference app was still running. The script now terminates it
   before recording.

Checked and matching: the toolbar shapes and spacing against the TabsKit
Demo (back circle, title capsule, tabs circle), the composer 8 pt above the
toolbar, the grid's 2-column cards, title rows and bottom bar (+, "3 Tabs",
Done), the Messages row metrics (26 pt dot gutter, 45 pt avatar, text at
83 pt, separators inset to the text, date with chevron), and the large
title.

## Known gaps

- **Pinch and swipes are not in the recordings.** simctl cannot inject
  touches. The grid zoom in the recordings uses the same `TabZoomDriver`
  spring as a pinch, through TabsKit's `isShowingOverview` binding. The
  pinch tracker, toolbar swipe and edge-swipe back need a hand check on a
  device or with UI tests.
- **New tabs from the demo** go through `createTab` directly. The grid's
  (+) zoom from the placeholder card is TabsKit's own path and was not
  recorded.
- **Browser cards** show a globe until the tab has been on screen once, as in
  Safari for unloaded tabs.
- **The Chief header's trailing button** (`clock.arrow.circlepath`) has no
  action. CmuxConversation does not expose a hook for it. Thread history
  (SPEC 6.1) needs a public callback in that package.
- **`ChiefDaemonBackend` has only been tested against a fake daemon.** The
  real daemon accepts `conversation-*` only on trusted local connections.
  Whether a `cmux-mobile-host` splice counts as trusted, and which principal it
  gets, is undecided (PROTOCOL.md lists conversation commands on the
  allowlist). Attachments are refused until `conversation-attachment-upload`
  is allowlisted.
- **Home's swipe actions** (Unread, Hide Alerts, Delete) are local view
  state only.
- **The outgoing bubbles** keep CmuxConversation's iMessage blue gradient,
  for Messages parity. The mobile neutral accent was not applied inside the
  transcript.
- **`CmuxConversation` gained one lab verb.** `react <tapback>` picks a
  tapback in the open bar through the overlay's own handler. It is the only
  change to that package.
- **Light mode was not recorded** for these flows.
- **No Instruments hitch trace** was run. The simulator does not support the
  Hitches template.
