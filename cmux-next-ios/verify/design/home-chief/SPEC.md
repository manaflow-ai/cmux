# Home and Chief design spec

Designer pass, 2026-10-14. Scope: the Home tab (conversation list, Chief pin,
search, filter, compose, navigation title), the Chief 1:1 conversation
(CmuxConversation), and Chief's details page.

## What was looked at

- **Build:** Debug simulator app from `origin/feat-cnx-ios` `ae6354ff98`
  (`dev.cmux.mobile`). `Packages/iOS/CmuxConversation` is byte-identical to
  `origin/feat-imsg-parity-gui` (`git diff HEAD origin/feat-imsg-parity-gui --
  Packages/iOS/CmuxConversation` is empty).
- **Simulator:** one headless `cmux-mobile-design-home`, iPhone 17 Pro, iOS 26.5,
  402 x 874 pt. Simulator.app was never opened. Taps and drags were HID
  touches through `axe`. The simulator was deleted afterwards.
- **Content:** mock content (`CMUX_MOBILE_MOCK_AUTH=1`; **mock (layout only)**). No
  message was sent, and no model was called. The details page in its connected
  state comes from the live run of 2026-10-13
  (`raw/c90-live-*.png`, copied from the chieflive evidence). That state
  could not be produced with mock content.
- **References:**
  - Messages on the iOS 26 simulator: `raw/ref-messages-list-ios26.png`
    (from the ws evidence).
  - For 1:1 conversation behavior, the reference is CmuxConversation's own
    measurement of Messages (`TimestampDrawerRows`, iOS 26 header wash; see
    `verify/imsg-parity.md`).
  - ChatGPT and Claude lists: `~/Downloads/cmux-native-references/`
    (`chatgpt-03`, `chatgpt-31`, `claude-01`).
  - The Mac's Chief settings: `Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeChiefSidebar.swift`.
- **Load:** 1-min load was 32 when the recordings started (bounded wait for
  < 40). It rose during capture, so durations are ± 0.2 s.
- **Units:** points. The files in `raw/` were downscaled to 402 px wide,
  so 1 px = 1 pt. AX frames are from `axe describe-ui`.

### Does the current Mac build serve Chief?

**Yes.** The E2E failure ("needs a newer cmux daemon (the chief.* operations)")
came from the older rig Mac. This was checked from the binaries; no Mac app
was launched.

| Mac app | `cmux-mobile-host` has the `chief` service (`chief.engine.get/set`, `chief.stop`) | `cmux-tui` has `chief.*` |
| --- | --- | --- |
| E2E rig `cmux-mobile-e2e-210e55d9` | **No** (0 matches) | Yes |
| E2E rig `cmux-mobile-e2e-604fc689` (PR #20414 head) | Yes | Yes |
| Prod build `~/cmux-mobile-builds/20261014-604fc6893a-mac-prod` (`cmux-mobile-host` commit 604fc689, `cmux-tui` 0f0d8ecc) | Yes | Yes |

The rig's README does not say it is free, so it was not used. Re-run the
Chief E2E journey against the 604fc689 Mac app.

## Images

| File | Shows |
| --- | --- |
| `img/01-home-vs-messages-chatgpt-claude.png` | Home, Messages iOS 26, ChatGPT and Claude lists |
| `img/02-chief-identity-four-avatars.png` | Chief drawn four ways: sparkles, "C" purple, "C" gray, sparkles |
| `img/03-chief-transcript-dark-light.png` | Transcript top (service line), open at bottom, light |
| `img/04-plus-menu-and-long-press.png` | "+" menu in dark and light, long-press menu |
| `img/05-timestamps-held.png` | Send-time drawer held |
| `img/06-keyboard-scrolled-up-r1-sheet.png` | Keyboard from a scrolled-up transcript, interactive dismiss (2.5 fps) |
| `img/07-keyboard-at-bottom-r2-sheet.png` | Keyboard at the bottom, interactive dismiss (5 fps) |
| `img/08-timestamps-r3-sheet.png` | Send-time drawer drag (6 fps) |
| `img/09-details-mock-live-light.png` | Details: mock, live, model menu (live), light |
| `img/10-new-message.png` | New Message empty, and with "c" typed |
| `img/11-ax5.png` | AX5: Home, Chief, details |
| `img/12-home-light-filter.png` | Home light, filter menu |
| `raw/r1..r4-*-402w.mp4` | Recordings: keyboard (scrolled up), keyboard (bottom), send times, back and compose |

## Priority list

| # | Level | Screen | Change | Owner |
| --- | --- | --- | --- | --- |
| 1 | Blocker | Home | The compose button opens the existing Chief conversation with the keyboard up (user decision, see 1.4) | mobile |
| 2 | Blocker | Home | Fix the AX5 layout: today titles truncate to "Cla…", the time wraps to "1:14 A / M", and the search text is clipped | mobile |
| 3 | Major | Home, header, New Message, details | Draw Chief one way everywhere, using the Mac's avatar: today it has sparkles in two places and "C" in two others | mobile + Mac |
| 4 | Major | Chief transcript | Render Chief's Markdown (inline code, bold, lists): today raw backticks show | upstream |
| 5 | Major | Chief transcript | Remove the lock glyph from "Runs your agents on your Macs": it claims encryption | upstream |
| 6 | Major | Details | Show what the Mac shows: the resolved default model, readable recent turns, the Avatar field. Remove dead-looking controls | mobile |
| 7 | Major | Home rows | Identify rows by the workspace, not by "Claude"; use the harness mark as the avatar; make "needs you" readable | mobile |
| 8 | Major | Home, Chief | Keep the hidden team sidebar out of the accessibility tree | mobile |
| 9 | Major | New Message (if kept) | Fix the subtitles ("Chief Runs your agents", "Claude cmux") and use the Home avatars | mobile |
| 10 | Polish | Chief pin | Show Chief's state without opening the chat; tighten the 150 pt pin block | mobile |
| 11 | Polish | Home filter | Make filters apply to Chief too | mobile |
| 12 | Polish | "+" menu | Add Camera; blur the transcript behind the menu as Messages does | upstream |
| 13 | Polish | Chief transcript | Keyboard from a scrolled-up transcript: check against Messages, then match it | upstream (verify first) |
| 14 | Polish | Mock data | Fix the out-of-order seed times (11:17 PM sent before an 11:16 PM reply) | mobile (DEBUG only) |
| 15 | Keep | Chief transcript | Send-time drawer, long-press menu, interactive keyboard dismiss and the header wash already match Messages. Change nothing | none |

---

## 1. Home

### 1.1 Navigation title

**Now:** there is no visible title. `ConversationsHome` sets
`.navigationTitle("Conversations")` with `.toolbar(removing: .title)`. The
toolbar is 62-116, search 116-168, and the Chief pin 168-318 (AX).

**Spec:** keep it as is. There is no visible title in any state, including
after scrolling. The user called it unnecessary, and ChatGPT and Claude
have none either. Keep `navigationTitle("Conversations")` for VoiceOver and
the long-press back menu only. Acceptance:

- No "Conversations" text renders at any scroll offset.
- A pushed agent chat's back button is a chevron only, with no text.

The agent chat back button was not captured; check it.

### 1.2 Rows (`img/01`, `img/12`)

| | Now | Messages iOS 26 (ref) |
| --- | --- | --- |
| Row height | 79 pt | 87 pt (separator to separator) |
| Unread gutter, avatar | 26 pt gutter, 45 pt monogram | ≈ 26 pt, 44 pt |
| Title x | 83 | ≈ 84 |
| Title | "Claude · cmux" (agent · workspace), body semibold | Contact name |
| Avatar | Initials of the tab title: every Claude row is "CL", every Codex row "CX" | Contact monogram or photo |
| Preview | 1 line used, 2 reserved | 2 lines |
| Needs you | A 7 pt `warning` dot after the preview. #FFCC00 on white is about 1.5:1 | none |

Problems:

- Five of the six rows start with the same word, and five share one avatar.
  To find a row you read past "Claude ·". ChatGPT and Claude list the topic
  only.
- On light, the needs-you dot is nearly invisible. It has no text, so it
  reads as decoration.

**Spec:**

- **Title:** the workspace title ("cmux", "cmux-next-ios"), body semibold. When a
  workspace has more than one agent tab, use "cmux · Codex" for the second
  and later tabs only.
- **Avatar:** 45 pt circle on the existing `monogramGradient`, with the
  harness mark (Claude or Codex glyph, 20 pt, white) in place of initials.
  If there is no glyph asset, use "CL" and "CX" as today.
- **Preview:** keep 2 lines reserved (Messages). Keep the date and the
  chevron as today.
- **Row height:** 10 pt vertical padding gives 79 pt; use 12 pt top and
  bottom to land on 83 pt. Not exactly 87: the title is one line and no
  contact photo is needed.
- **Needs you:** replace the dot with the leading gutter mark Messages uses
  for unread, in `warning` color. That is a 10 pt filled circle in the 26 pt
  gutter, with the accessibility label "Needs you". Unread (`label` dot)
  wins over needs-you if both apply. The dot needs at least 3:1 against
  the background in both appearances. Use #C93400 on light (4.9:1; system
  orange #FF9500 is only 2.2:1) and #FF9F0A on dark.

### 1.3 Search field

**Now:** a list row, a 36 pt capsule, `surfaceRaised`. At AX5 the "Search"
placeholder is taller than the capsule and is clipped (`img/11`).

**Spec:**

- The height is `max(36, scaled line height + 14)`, using
  `@ScaledMetric(relativeTo: .body)`.
- The glyph scales with the text.
- The field scrolls with the list (as now). Messages iOS 26 puts search at
  the bottom, but the tab bar is there, so the top is right.

### 1.4 Compose (`img/10`, `raw/r4-back-compose-402w.mp4`)

**Now:** the compose button opens New Message (CmuxConversation's
`ConversationComposeViewController`) with an empty "To:" field and a
keyboard. A first send routes to Chief or to an agent chat.

**Conflict:** this round's brief describes the compose button as the one
"that opens the existing Chief conversation". `verify/chief-parity.md`
(round of 10-13) records the opposite feedback: "Compose opened the existing
Chief chat. That was not intended." The user needs to settle this:

- **Decision for the user:** what should Home's compose button do? Reply
  `compose opens Chief`: the button pushes the existing Chief conversation
  with the composer focused, and New Message is removed from Home. Or reply
  `compose opens New Message`: the button keeps today's New Message sheet
  (To: Chief or an agent), with item 9's fixes.

**Recommendation and spec (`compose opens Chief`):**

- Why: the phone cannot create conversations (`conversation-create` is
  refused), so every recipient New Message offers is already a row on Home.
  Chief routes work to agents itself. An empty "To:" field is one more step
  in front of the only new thing the user can do, which is to ask Chief.
- Tap: push `ChiefRoute` with the same push as tapping the pin. After the
  push settles, focus the composer: the keyboard rises in the same run loop
  turn as `viewDidAppear`, with no delay. The draft is kept.
- Accessibility label: "New Message to Chief". Glyph: `square.and.pencil`
  (unchanged).
- Long press on compose: nothing. Agent chats open from their rows.

### 1.5 Chief pin (`img/01`, `img/02`)

**Now:** an 88 pt avatar, centered, with 26 pt above and 14 pt below. The
whole block is 150 pt tall (168-318) for one pin. It shows a preview bubble
only while there are unread messages, and a typing bubble while Chief types.

**Spec (Polish):**

- Top padding 26 → 14 and bottom 14 → 10, so the block is 136 pt.
- When there is no unread message and Chief is idle, show nothing extra (as
  Messages does).
- When Chief is waiting on you (an outbox item, or a Chief message that asks a
  question and is unread), show the preview bubble even after the unread
  count clears, until you open the chat.
- The "Chief" caption is footnote, `label` (as now).

### 1.6 Filter (`img/12`)

**Now:** "All Conversations / Unread / Needs You" filters agent rows only.
Chief's pin always shows.

**Spec (Polish):**

- Unread hides the pin unless `session.unreadCount > 0`.
- Needs You hides it unless the outbox is not empty or `session.isTyping` is
  false and the last message is Chief's and unread.
- While a filter other than All is active, an empty result shows
  "No Conversations" (callout, `label2`, centered 120 pt below search).

### 1.7 AX5 (`img/11`, blocker)

**Now:** at accessibility-extra-extra-extra-large:

- The title truncates to "Cla…" and "Co…".
- The time wraps over two lines ("1:14 A / M").
- The chevron sits beside it.
- The 45 pt avatar does not scale.

**Spec:** at accessibility sizes, stack the row the way Messages does:

- Line 1: the title, full width, up to 2 lines.
- Line 2: the date, then the chevron.
- Then the preview, up to 3 lines.

Details:

- The avatar scales with `@ScaledMetric(relativeTo: .body)`, capped at 64 pt.
  It stays top-aligned.
- The time never wraps: `lineLimit(1)`, `fixedSize()`.
- The pin caption may wrap to 2 lines.

## 2. Chief identity (`img/02`, Major)

**Now:**

| Place | Drawing | Source |
| --- | --- | --- |
| Home pin | sparkles on the purple gradient | `ChiefAvatar` |
| Chat header | "C" on the purple gradient | `ChiefIdentity.chief.initials` |
| New Message | "C" on gray | `ChiefDirectory` contact |
| Details | sparkles | `ChiefAvatar` |

The Mac's Chief has an **Avatar** field (`HomeChiefSidebar` `avatarField`;
default: initials). That field is in the Mac's `optchat/profile.json`, which
has no daemon command (`verify/chief-mac-parity.md`).

**Spec:**

- One rule everywhere: Chief's avatar is the Mac's avatar text. That is an
  emoji or 1-2 letters, default "C", drawn white on `monogramGradient`.
  - Home pin: 88 pt.
  - Header: the package's size.
  - New Message: 40 pt.
  - Details: 72 pt.
- Retire the sparkles glyph.
- In the chat header, set `ChiefIdentity.chief.initials` to the avatar text.
  That needs no package change.
- In New Message, give the contact the same text and `colorHex`, so it uses
  the package's gradient, not gray.
- **Mac side (not CmuxConversation):** add `avatar` to the `chief.engine.get`
  reply (read from `profile.json`) and an `avatar` field to
  `chief.engine.set`. Until that lands, use "C".

## 3. Chief conversation

### 3.1 What already matches Messages: keep

- **Send-time drawer** (`img/05`, `img/08`): in this 1:1 chat the blue
  bubbles slide left. The gray bubbles stay. **Every** row, incoming and
  outgoing, shows its time (11:15 PM, 11:16 PM, 11:17 PM, 11:40 PM, 11:41
  PM). This is the package's measured Messages behavior
  (`TimestampDrawerRows`, iOS 26.5 and 27.0). It matches the user's
  correction: do it the iMessage way. Do not bring back a host option that
  slides incoming rows in a direct chat.
- **Long-press menu** (`img/04` right): the bubble lifts, with the tapback
  bar above it and Reply / Copy / Translate / Select / More… below.
- **Interactive keyboard dismiss** (`img/07`, 4.0-4.8 s): the keyboard tracks
  the finger down, and the transcript follows.
- **Keyboard at the bottom** (`img/07`, 1.0-1.2 s): the newest message rides
  up above the composer.
- **Header wash** (`raw/b02`): rows under the header and the status bar get
  the iOS 26 color wash (peak 0.60), as measured in Messages; on iOS 27 they
  blur. It looks busy with a long first bubble, but it is Messages. Keep it.

### 3.2 Markdown shows raw (`img/03`, Major, upstream)

**Now:** Chief's "Heads up: … asking to run \`cargo test -p cmux-mobile-link\`. Want me
to allow it?" shows the backticks. Chief's turns are written in Markdown.

**Spec:**

- Incoming agent text renders inline code (SF Mono, the bubble's size, 1 pt
  tighter), **bold**, *italic*, links, and `-` lists.
- A fenced block becomes a monospaced paragraph inside the bubble. It scrolls
  horizontally only when it is wider than the bubble.
- Copy keeps the source text.
- Outgoing (your) text stays plain, as in Messages.
- **Upstream CmuxConversation:** a run kind for `code` in
  `ConversationRichText`, or a host flag `rendersMarkdown` on
  `ConversationPresentationOptions`.
- **mobile (no package change):** `ChiefDaemonBackend` maps Chief's Markdown to
  runs. The phone does not edit the text.

### 3.3 Service line (`img/03` left, Major, upstream)

**Now:** "Chief / 🔒 Runs your agents on your Macs". The lock comes from the
Messages "Encrypted" line. It makes a security claim the Chief link does not
make in this sentence.

**Spec:**

- Title "Chief" and subtitle "Runs your agents on your Macs", with **no
  lock**.
- **Upstream CmuxConversation:** add `serviceSymbol: String?` to
  `ConversationPresentationOptions` (default `"lock.fill"`, so Messages parity
  is unchanged), and pass `nil` for Chief.

### 3.4 "+" menu (`img/04`, Polish, upstream)

**Now:** Photos and Files in a glass menu. The transcript behind it stays
sharp at full brightness.

**Messages iOS 26:** Camera first, then Photos and the other apps. The
transcript behind the menu is blurred and dimmed.

**Spec:**

- Items: Camera, Photos, Files, in that order. Camera uses the system
  camera picker. A taken photo is an attachment, the same as one from
  Photos.
- Behind the menu: the transcript and composer blur (`systemUltraThinMaterial`
  strength) and dim to 70%. The blur animates in with the menu's spring and out
  with its dismissal.
- **Upstream CmuxConversation:** a host-supplied list of menu items
  (`ConversationAttachmentSource` options: camera, photos, files), plus the
  backdrop blur.

### 3.5 Keyboard from a scrolled-up transcript (`img/06`, Polish, verify first)

**Now:** with the transcript at its top, tapping the field raises the
keyboard (1.6 s in r1). The composer then sits over "One thing…", and the
rows below it are hidden. The content offset does not change.

**Spec:** first compare with Messages, scrolled up the same way. Messages
keeps the row that was just above the composer visible above it, shifting
the content up by the keyboard height. If it does, match it upstream. If it
does not, keep the current behavior. Do not change mobile for this.

### 3.6 Header avatar

See section 2. The name pill "Chief ›" opens the details. It stays as it is.

## 4. Details page (`img/09`, Major)

### Now

**Mock, no control:**

- Header: sparkles avatar, "Chief", and "Runs on your Mac".
- Model: "Connect to your Mac to choose Chief's model."
- Hide Alerts and Send Read Receipts toggles.
- A Name field showing "Chief".
- Footer: "Chief's memory and traces open on the Mac."

**Live, 10-13:** Harness Codex, Model **"Default"**, Effort High. Recent
Turns shows **"claude" / "error · 2m 57s"**. The model menu lists "Default"
first with no name.

**Mac `HomeChiefSidebar`:**

- Name and **Avatar** fields.
- Harness, Model and Effort pop-ups. The default entry is labelled with what
  it resolves to.
- The next-turn note.
- Stats and replies.
- The brain path.
- Open Traces, and Show Memory (DEV only).

Problems:

1. The status line ("Runs on your Mac") contradicts the Model section
   ("Connect to your Mac…") when Chief has no control channel.
2. The Name field renders as an active white text field while it is
   `.disabled` (no control). It looks editable and does nothing.
3. Model "Default" does not say which model. The menu's "Default" has no
   name either. `defaultLabel` only names it when `engine.model` is set, and
   with Codex it is nil.
4. Recent turns show raw ids and status ("claude", "error").
5. The Mac's Avatar field is missing.
6. The sheet's navigation title "Chief" repeats the large name under the avatar.

### Spec

Sheet: `.pageSheet` with a grabber (as now). Toolbar: Done only, with **no
title** (problem 6).

| Section | Rows | When there is no control channel |
| --- | --- | --- |
| Header | As Messages' contact details (`verify/chief-info.md`): avatar (section 2) 80 pt in the navigation bar's row; name title bold; status subheadline `label2`; Message and Stop quick actions | Status = the reason (`session.unavailableReason`, e.g. "Your Mac isn't reachable"), never "Runs on your Mac" |
| Model | Harness, Model, Effort as menu pickers (as now). The default item reads "Default (GPT-6.1 Sol)", from `offered` and the harness default. Footer: "Changes apply to Chief's next turn, on every device." | One row, "Connect to your Mac to choose Chief's model.", `label2`. No pickers |
| Running | The Stop quick action in the header, enabled while Chief is typing | Dimmed |
| Recent Turns | Up to 5 rows. Line 1: model display name ("Claude Opus", "GPT-6.1 Sol"), or the harness name ("Claude", "Codex"). Line 2: "Failed · 2 min 57 s · 3 tools · $0.04", with the status localized (Completed, Failed, Stopped) | Hidden |
| Notifications | Hide Alerts, Send Read Receipts: native `Toggle`s (as now; the native switch animation was verified live on 10-13) and footer (as now) | Disabled with the standard dimming (they need a conversation id) |
| Identity | Under Edit in the bar: "Name" row: label left, value right (`label2`), pushes a one-field edit page with Save. "Avatar" row the same, if the Mac exposes it (section 2) | Hidden. No dead controls |
| Footer | "Chief's memory and traces open on the Mac." | Same |

Every control either acts on the Mac's Chief or on this phone, or it is not
shown. Do not use any `.disabled` control that looks active.

## 5. New Message (if the user keeps it; `img/10`)

- **Subtitles:** "Chief Runs your agents" is the handle label and the value
  run together, and "Claude cmux" repeats the title.
  - Chief: "Runs your agents on your Macs".
  - Agents: "Claude on <Mac name>", or the workspace path when the Mac is not
    known.
  - Set the handle label to "" if the package prints label then value.
    Otherwise make an upstream request for a `subtitle` on
    `ConversationContact`.
- **Avatars:** the same avatars as Home (section 2 and 1.2), not gray.
- **Empty "To:":** list the recipients below the field before typing (Chief
  first). Today the sheet is blank until a letter is typed. This is
  CmuxConversation behavior; make it an upstream option
  (`showsSuggestionsWhenEmpty`).
- **Composer:** the field has no placeholder. Use "Message" (upstream
  default).

## 6. Accessibility tree (Major)

On Home and in Chief, `axe describe-ui` lists the team sidebar's elements
(Manaflow, Personal, Build Fleet, Invite to team, Add team) at x -40…262,
while the sidebar is closed. VoiceOver can land on controls that cannot be
seen. Spec: while the sidebar is closed, the sidebar container has
`accessibilityHidden(true)`, and the shell content does not. When the
sidebar is open, the reverse applies, and the content gets an "escape"
action that closes the sidebar. This was not checked with VoiceOver on.

## 7. Mock data (DEBUG only)

`ChiefMockBackend`'s seed puts "nice. anything waiting on me?" at 11:17 PM
before Chief's 11:16 PM reply (`img/05`). Order the seed so each reply is
later than the message it answers. The send-time drawer makes the error
visible.

## Upstream CmuxConversation requests (for the `feat-imsg-parity-gui` owner)

Do not fork the package locally. Each item keeps the Messages default.

| # | Request | Default (Messages parity) | Chief passes |
| --- | --- | --- | --- |
| U1 | `ConversationPresentationOptions.serviceSymbol: String?` | `"lock.fill"` | `nil` (3.3) |
| U2 | Markdown rendering for incoming text: inline code, bold, italic, links, lists, fenced blocks (a `code` run kind in `ConversationRichText`, or `rendersMarkdown`) | off | on (3.2) |
| U3 | Host-supplied "+" menu items (camera, photos, files) and the blurred, dimmed transcript behind the menu | Messages' set | camera, photos, files (3.4) |
| U4 | Verify the keyboard rising from a scrolled-up transcript against Messages; match it if it differs | n/a | n/a (3.5) |
| U5 | New Message: suggestions when "To:" is empty, and a contact `subtitle` | off / handle | on / Chief's subtitles (5) |
| U6 | A hook to replace the contact details (today Chief retargets header buttons by accessibility id, `ChiefConversationContainer.takeOverHeader`) | package details | `ChiefSettingsView` |

U6 was already filed in `verify/imsg-upstream-requests.md`. It is listed again
because the header takeover breaks silently if the ids change.

## Not captured, and why

- **Live Chief** (the connected details page, model menu and recent turns
  today, a real typing bubble, a Chief preview on the pin): the E2E rig's
  README does not mark it free. Using it, or a tagged build on
  `mini-cmuxs-mac-mini-2`, would also need a send to see Chief move, which
  would be a paid model call. The 10-13 live captures stand in.
- **Messages iOS 26 conversation, "+" menu and long press:** the simulator's
  Messages cannot hold a conversation. The 1:1 behavior reference is the
  package's own measurement. Sections 3.4 and 3.5 say what to check on a real
  Messages capture.
- **Agent chat back button** and the push from a Home row: not opened.
- **VoiceOver:** the sidebar finding (6) is from the accessibility tree, not
  a VoiceOver run.
- **Timing:** load was 32 to 70 during the recordings. Positions are
  reliable, and durations are ± 0.2 s.
