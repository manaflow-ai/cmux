# Chief on iPhone vs Chief on the Mac

Branch `feat-cnx-ios-chieflive`, 2026-10-13. The user asked that Chief on
iPhone be the Mac's own Chief, at parity with cmux-next on macOS, and that
the details page have no dead controls.

## What "the Mac's Chief" is

Chief is not part of a build's own daemon. It is one home per account,
`~/.cmux/chief/<account>`, which every cmux-next build on the Mac shares
(`ChiefHome`). That home has three parts:

- **Conversation owner:** a detached cmux-tui session, `cmux-chief-<FNV-1a of
  the home path>`.
- **Brain host:** `optchat-chief host`. It binds as `agent_mux` and runs
  turns.
- **acpmux:** runs Chief's turns and subagents.

Home finds the oldest conversation that includes `agent_mux`
(`HomeChiefName.select`). If none exists, it creates one with its own
idempotent request.

The phone now talks to that owner over a new cmux-mobile-host service, `chief`. The
service filters both directions and only reaches the owner's conversations
with agents. The analysis is in `cmux-next-ios/SECURITY.md`, section `chief`.

`ChiefDaemonBackend` finds the same conversation that Home shows. The phone
never creates Chief. The phone has no mock Chief in Production. If Chief is
unavailable, the phone shows one of three states, each with its reason:

- The Mac is unreachable.
- The Mac's cmux is too old to serve Chief.
- Chief has not started on the Mac yet ("Open Home in cmux on the Mac").

Before this change:

- Chief looked for `agent_chief` on the app's tagged daemon over `daemon`, an
  id the Mac never uses.
- It created its own conversation.
- The hostd allowlist refused every `conversation-*` command, so production
  Chief was always `ChiefOfflineBackend` (audit B4).

## Parity matrix

The macOS sources are under `Packages/macOS/CmuxNext/Sources`.

| Mac feature | Mac implementation | iPhone | How |
| --- | --- | --- | --- |
| Chief conversation in Home | Owner `conversation-list`, oldest with `agent_mux` | Yes | `ChiefWire.chiefConversation`, `chief` service |
| Send, live transcript, typing | `conversation-op message.send` (`client_msg_id` = key), `conversation-changed`, `conversation-typing` | Yes | Same commands. A rev gap refetches. |
| Read state | `read_cursor.set` | Yes | Same, unless Send Read Receipts is off (see below). |
| Reactions, edit, unsend, reply | `reaction.*`, `message.edit`, `message.retract`, `reply_to` | Yes | Same ops |
| Mentions | `TextRun{mention}` runs (`HomeMentions.runs`) | Yes | Composer mentions become `runs` with the participant id; incoming runs become mentions. |
| Attachments | `conversation-attachment-upload` / `-read` | Yes | Begin, then 2 MiB chunks, then commit. Reads are by hash. |
| History | `conversation-snapshot` / `-history` | Yes | Same |
| Threads | `conversation-thread` | Allowed by policy, no UI | The iMessage package has no thread view. Replies show inline. |
| Search | `conversation-search` | Allowed by policy, no UI | Home's search field filters agent rows only. A Chief transcript search needs a package hook. |
| Harness / model / effort | Chief Settings sidebar pickers → `chief.engine.set` (`ChiefControlClient`) | Yes | `ChiefSettingsView` pickers → `ChiefControl.setEngine`. The lists come from `chief.engine.get` `offered`, and "Default (…)" clears a field, as on the Mac. |
| Recent turns | `chief.engine.get` `recent` | Yes | Settings: model, status, time, tools, cost |
| Stop | `chief.stop` (button, Esc, ⌘.) while Chief is typing | Yes | Chief's info: the Stop quick action (dimmed unless Chief is typing) |
| Rename | `title.set` | Yes | Chief's info: Edit > Name |
| Avatar | Written to `optchat/profile.json` on the Mac | No | A local file on the Mac, with no daemon command. The phone shows Chief's avatar. |
| Memory inspector, traces | Local browser tab, Finder | No | Owner-only on the Mac. `chief-inspect` stays refused. Settings says so. |
| New Message to Chief / agents | `conversation-create` (`agent_mux`) | Partly | New Message routes to the Chief conversation or to an agent chat. The phone does not create new owner conversations: `conversation-create` is refused. |
| Subagent links `cmux://chief/…` | Opens the subagent's tab | No | The phone has no Chief-home acpmux route yet. |
| "Organizing N/M" notice | Watches `state/settle.json` | No | A local file on the Mac |
| Streaming draft | `conversation-draft` via `conversation.events` (v2 stream) | No | Not on the raw `subscribe` stream. The typing indicator shows instead. |
| Cloud Chief (placed on a server) | `v1/read chief.list`, cloud conversations | No | `cloud-*` is refused on the phone. |
| Notifications / muting | None on the Mac | Yes (phone only) | Hide Alerts: local alerts for Chief's messages, muted per conversation |

## Details page

The old page was CmuxConversation's contact details. It had Call, FaceTime
and Mail (always disabled), plus Hide Alerts and Send Read Receipts on a
table that reloads under the switch. A tap there snapped the switch and then
put it back, because Chief's backend rejected list-state changes.

CmuxConversation has no hook to replace or trim the details
(`verify/imsg-upstream-requests.md`). Instead, Chief points the header's
avatar, name and trailing button at `ChiefSettingsView`, pushed like Messages'
contact details (`verify/chief-info.md`):

- **Hide Alerts:** stored per conversation on this phone (`ChiefPreferences`)
  and reported back through the store's list state.
  - While it is off, every new message from Chief posts a local notification,
    unless the Chief conversation is on screen. Alerts show as banners in the
    foreground.
  - Turning it on removes alerts already delivered.
  - Home's Chief pin has the same action and shows a bell when alerts are
    hidden.
- **Send Read Receipts:** controls whether reading on the phone moves the
  owner's read cursor (`read_cursor.set`), which the Mac and Chief see.
  - While it is off, the phone keeps its read position locally.
  - Turning it back on reports that position.
  - Chief has no other receipt concept.
- **Animation:** both switches are SwiftUI `Toggle`s over local state, so a
  tap animates natively. A rejected save puts the switch back with
  animation.
- **Removed:** Call, FaceTime and Mail no longer appear for Chief.

## Audit items

- **B4, Chief offline in production:** the `chief` service, described above.
  Live verification against a real Mac app build is in the next section.
- **B9, a first message to Chief could be lost:** New Message now calls
  `ChiefSession.send`.
  - Before Chief connects, the message waits in `ChiefOutbox`, a file in
    Application Support, so it survives a backend swap and a relaunch.
  - Home's preview reads "Waiting to send: …". Opening Chief shows the reason
    and offers Keep or Delete.
  - The message goes out once Chief connects. From then on, the transcript
    shows Delivered, or Not Delivered with retry.
- **Chief status:** `LiveCoordinator` passes the real reason to
  `ChiefSession.status`. Home's preview and Settings show it.

## Verification

- **cmux-mobile-host:** `cargo test -j 4 -p cmux-mobile-host` ran 20 unit tests and 4 link
  tests, all passing. The link tests run `exercise_services` over WebRTC,
  WireGuard and the relay against a fake owner. `cargo clippy` is clean.
- **CmuxMobileChief:** `swift test --filter CmuxMobileChiefTests` on
  `mini-cmuxs-mac-mini-2` (macOS, Xcode 26.3) ran 16 tests, all passing:
  - The phone finds Chief and does not create it.
  - It reports an honest disconnect when Chief has not started.
  - It picks the oldest Chief conversation.
  - Mention runs round-trip.
  - With receipts off, no `read_cursor.set` is sent; turning receipts on
    reports the position.
  - It decodes the engine control replies.
  - The outbox is kept on disk and flushes on connect.
  - The existing send, attachment and mock tests still pass.

  The iOS run of the same scheme could not build on that mini: Xcode 26.3
  fails in CmuxTabsKit `Toolbar.swift:372`, the known
  `tabskit-upstream-requests.md` item.
- **UI:** `verify/record-chief-settings.sh <udid> ios26` on simulator
  `cmux-mobile-chf2-ios26` (iOS 26.5, headless, mock content).
  - The demo found and retargeted the header controls
    (`header taken over: true`) and opened the settings sheet.
  - It flipped each switch the way a binding change does. The 30 fps frames
    (`flip-*`, git-ignored evidence) show the knob sliding and the track
    tinting over about 6 frames, the native `UISwitch` animation.
  - simctl cannot inject touches, so the tap itself is a hand check.
- **Live:** see `## Live run` below.

## Live run (2026-10-13)

**Setup**

- **Mac:** `cmux DEV cmux-mobile-chief-dev`, a real cmux-next app, fleet job
  `f0a796f8d401e021b7579bd0`. It was built from `feat-cnx-ios-chieflive-mac`
  (fafff32f), which is `feat-cnx-ios-machost` merged with this branch. It
  bundles the new cmux-mobile-host.
  - It ran on `mini-cmuxs-mac-mini-2` in the `cmux` GUI session.
  - It signed in with the dev Stack test account from the DEBUG credential
    file, and Settings > Mobile was on (`CMUX_NEXT_CONFIG_FILE`).
  - The Chief home was `~/.cmux/chief/default` (owner
    `cmux-chief-b902d10e`). The OptChat brain was already running there from
    another DEV build.
- **Phone:** simulator `cmux-mobile-chf2-ios26` (iOS 26.5, headless), Debug build,
  signed in with the same account. The phone was pointed at that Mac. Taps
  were real HID touches (`axe`).

**Results**

- **Channel:** hostd logged `channel opened service="chief"`. The phone
  showed the Mac's own Chief conversation (`conv_01M4W6…`, `user_local` and
  `agent_mux`, created by the Mac at 03:17Z). The phone created nothing.
- **First message:** sent from the phone, it was Delivered, then Read by
  Chief, with Chief's typing bubble. The brain started a real turn
  (`turn.start` in its trace).
  - The turn failed on the mini's inference gateway: "API Error: 503 no
    accounts available", from the subrouter at 127.0.0.1:31415.
  - Chief posted that failure into the conversation, and the phone showed
    it.
- **Settings:**
  - The settings sheet loaded `chief.engine.get` from the brain: harness
    Claude, effort Default (Medium), the codex model list (GPT-6.1 Sol and
    others), and recent turns ("claude · error · 2m 57s").
  - Picking Effort High, then Harness Codex, wrote the brain's `engine.json`
    on the Mac (`{"harness":"codex","effort":"high"}`).
  - The next message from the phone was answered by Chief on Codex: "Hi,
    you're now on Codex." The phone showed the reply.
- **Switches:** real taps on Hide Alerts and Send Read Receipts.
  - Both values persisted (`cmuxMobile.chief.<conversation>.muted/.receipts`).
  - The recording, frame by frame, shows the native iOS 26 switch animation:
    the glass knob lifts, slides and settles while the track tints. It takes
    about 25 frames, with no jump.
- **Read receipts:** with receipts off, the owner's `user_local` cursor
  still advanced. The op ledger shows it was set twice per message, by the
  two Mac Homes (two DEV builds) that share this Chief and also act as
  `user_local`. The live run cannot tell the phone apart from them. The unit
  test `receiptsOffKeepsTheReadPositionOnThePhone` covers the phone side.
- **Cleanup:** the brain's engine was restored with `chief.engine.set
  harness/effort default` (`engine.json` is `{}` again). The app was quit,
  `~/cmux-next-ios-e2e/chieflive` was removed, and the simulator was deleted.
- **Evidence:** `verify/evidence/2026-10-13/chief-live/` (git-ignored):
  `toggles.mp4`, `sheetA.png`, `codex-reply.png`, `settings-codex.png`,
  `models.png`.

**Not verified live**

- **Release build:** the production Release build of the same ref (fleet job
  `56b6e9cff7206595daa4174f`, `--release --production`) failed in a
  `swift-frontend` crash while compiling `CmuxNextDesign` with whole-module
  optimization on Xcode 26.6. That target is untouched here; it comes from
  the machost/feat-cmux-next base. Release builds also do not start the
  Chief brain.
- **Alerts:** banners need the app off the Chief screen while a reply
  arrives. They were not exercised live.
