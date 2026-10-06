# CmuxMessagesLab

The cmux-next Mac Home transcript is MessagesLab's own code
(`~/fun/messageslab`, variant appkit-native), not a rewrite: its rows,
springs and timing curves (`springs.json`), send morph, Liquid Glass field
and render-server field animation, blurred header and native scrolling.

## Layout

- `Sources/MessagesLabHome/Vendor/`: MessagesLab files, byte-identical to the
  pinned commit except the blocker patches. `vendor.tsv` lists each upstream
  path and the pin (first line).
  - catalyst core: Model, Engine (types and the reducer, kept as a projection
    of HomeStore), Layout, Transcript, Recycler, RowDrawing, Springs, Morph,
    Shapes, Fixture, Header, WindowView, Replay, ComposeAttachments (the
    field's attachments: images as the image, 177 x 118 pt, stacked; files as
    tiles), LinkPreviews; `Resources/springs.json`.
  - appkit-port shim: UIKitNames, RoundedRect, LayerViews.
  - appkit-native: Compose, Materials, NativeScroll, HeaderBar,
    HeaderBackdrop, TranscriptAccess, SwipeReply (installed only when the
    owner can take a reply: `ChatIntents.canReply`, false until HomeOp has one),
    FlightRecorder (off until the app's policy, `HomeFlightRecorder`, turns it
    on: a Debug Settings opt-in in DEV and NIGHTLY until it costs at most 0.3 ms a
    frame, never Release or RC).
  - Not vendored (MessagesLab test drivers or app shell): App, Host, Bench,
    SelfTest, FlashCheck, AttachCheck, ResolutionAudit, LiveRecord,
    tools/diff-harness, PagedSource, Pager.
- `Patches/`: one unified diff per edited vendored file. Every edit is also
  marked `cmux:` in the source.
- `Sources/MessagesLabHome/Cmux/`: cmux code in the same module (the upstream
  files have no access modifiers): `PaneHost` (the pane host and controller,
  derived from Host.swift, keeping its type names and layer order),
  `HomeProjection`/`ProjectionCore`/`HomeDiff`/`HomeMapping` (HomeStore
  snapshots to MessagesLab actions; sends and tapbacks to HomeIntents),
  `PaneHeaderView` (HeaderBar's avatar and pill inside the pane),
  `HomeMedia` (attachment bubble pictures as `file:` assets MessagesLab's
  row drawing reads: local files first, else `HomeStoreBinding.fetchAttachment`),
  `HomeVideo` (inline video: lane 16's `VideoPlayback` players placed in
  MessagesLab's video bubbles under the bubble mask, with RowDrawing's play
  disc while paused), `CmuxStrings` (Resources/CmuxHome.xcstrings),
  `HomeLinkPreviews` (which links may fetch a preview), `HomeLinkSend` (the
  preview a send attaches),
  `HomeMarkdown` (an agent's Markdown as MessagesLab text and style runs;
  people's text stays plain), `HomeFlightRecorder` (the flight recorder's
  policy, log folder and Save Last 10 Seconds, plus the helpers it calls from
  unvendored MessagesLab files),
  `FixtureTheme` (cmux theme to Fixture colours), `MessagesLabHomeView`
  (the public view).

## Blocker patches

| file | why |
| --- | --- |
| Springs, Layout, TranscriptAccess, Model (fixture root) | resources live in the package bundle, not the app's main bundle |
| Model, Layout | live dates in the user's zone and locale (fixtures keep -07:00 and en_US) |
| WindowView, Compose | rows and field lines follow the view's own width (several Home tabs), not the process-wide `Metrics.current` |
| Fixture, Transcript, Morph | optional cmux theme; nil keeps MessagesLab's measured palette |
| Fixture | a theme without an accent keeps MessagesLab's measured blue, gradient and white text (`FixtureTheme.measuredAccent`) |
| Fixture, Transcript, Compose | typing dots, placeholder, waveform, caret and chip fill from the theme on a light theme; a dark theme keeps MessagesLab's measured values (the field glass and its buttons follow with the view appearance, `FieldChrome.applyTheme`) |
| HeaderBackdrop | the tint uses the theme background (MessagesLab's grey read as a band on a cmux pane) |
| Layout, Localizable.xcstrings | the placeholder says Message, not iMessage; the 69f4256 menu and delete strings carry all 21 app languages (upstream has en and ja) |
| Layout | a failed send that reached the owner unanswered says May Not Have Been Delivered (`CmuxStrings`, Resources/CmuxHome.xcstrings in every app language) |
| Engine, Materials | Xcode 26.6 compile fixes (`self.` capture; a macOS 27 SDK property by key) |
| SwipeReply | the pane controller's window is optional |
| RowDrawing | file, audio, contact and voice memo rows on my side use the theme's sent text colour (white by default; a light accent showed white text) |
| Engine, WindowView | `cmuxSetAttachment`: an attachment part's picture or upload state changed in HomeStore (no content change, no transition; the row redraws in place) |
| Compose | `onPastePasteboard`: the field's paste reaches the host's attachment intake first (Home's type rule, prepared by HomeStore) |
| Layout | styled runs (an agent's Markdown) break lines with the fonts they draw with; `code` runs draw monospaced |
| Layout | below 434 pt (Messages' window minimum; a Home pane has no per-content minimum and can be 80 pt) the text column keeps its 434 pt share of the width instead of the measured rule reaching 0 pt |
| NativeScroll | the drawn scroll indicator sits 2 pt from the scroller's own right edge (in a pane the window's edge is not the transcript's) |
| LinkPreviews | the cache lives in the app's own caches folder (`<bundle id>/link-previews`), not MessagesLab's; `cached(_:)` lets a HomeStore rebuild show a fetched preview again |
| ComposeAttachments | the image placeholder and file tile fill use the theme's chip fill on a light theme (a dark theme keeps the measured white) |
| FlightRecorder | the app's policy and log folder (`HomeFlightRecorder`), window captures behind their own opt-in, the pane's optional window (attached from `ChatController.windowChanged`, observers replaced), FlashCheck/LiveProbes/Bench/LiveRecord helpers from `HomeFlightRecorder` |

## Updating

```bash
scripts/cmux-next/sync-messageslab.sh <commit>       # copy, apply Patches/, record the pin, show the diff
scripts/cmux-next/sync-messageslab.sh --check         # vendored == pin + patches
scripts/cmux-next/sync-messageslab.sh --write-patches # after editing a vendored file by hand
```

A patch that no longer applies stops the sync; fix that file by hand, then
`--write-patches`.

Partial roll-ins: a vendor.tsv row with a third column takes that file from
its own MessagesLab commit (the pin stays for the rest), for upstream commits
that are wip checkpoints. Current pins (2026-10-06): every file at 85684b4
(85684b4 builds with Xcode 26.6 and 27 and keeps ScrollPrefetcher on the engine
clock; 02519e9 adds the light link card (#E9E9EB, `Fixture.lightAppearance` from the theme),
the outgoing-only LinkPresentation fallback (wired: `outgoingLinkOnScreen`,
`consider` on scroll, late answers fill the card), media fling paging inside the draw budget and recent emoji (`RecentEmoji`,
carried in Cmux/PaneInteractions.swift); earlier in this pin 89a1c5b, 2a0805d, 93cf61f,
bcfffae, 0fffbd2 and 48db8a7: long messages
collapse above 3 screens ("Show all N lines", EN and JA from upstream), header glass
and scroll indicator timing measured from Messages, resize anchoring like Messages, the
grey loading card and its fade-in, URLSession link previews through LinkGuard,
long text (LongText, TiledBubble, MediaCache), the scroller's knob drag and
track click, compose hover only over the field) except SwipeReply at 0c8147b
(not installed while HomeOp has no reply). Earlier in this pin: cd2bc08's link
rule, size cache keyed by part content, compose image previews; da2b8ae's text
column, 358.4 - 0.654 x (628 - W) pt.

The link rule on the Home path: HomeStore stores a text part as typed, and
`HomeMapping.projectedParts` shows it through the vendored
`TextParts.parts` (the rule MessagesLab's own send applies), so the local
send and the stored message show the same bubbles. A text with mentions
stays one bubble, and so does an agent's Markdown with a fenced block. A
split text is still one HomeStore part: a tapback on its card or its text
bubble is on that part and shows on its first bubble. A stored message's card
is never the grey loading card: it shows a fetched preview or the domain.

Link previews (coordinator decision 2026-10-06, as iMessage): the SENDER makes
the preview. `Cmux/HomeLinkPreviews` lets MessagesLab's `LinkPreviews` fetch
only for a link in a message this Mac sends, or a card the user clicks; a
received card shows what the sender attached, else the domain, and never
fetches by itself (no request to a URL another person or an agent chose, and
the receiver's address never reaches the sender's server). Every fetch goes
through MessagesLab's LinkGuard: http(s) on the default port, every resolved
address public (no loopback, private, CGNAT/Tailscale, link-local, ULA;
mapped and NAT64 IPv6 as IPv4), the connected address re-checked, at most 5
redirects each re-checked and no https to http, an ephemeral session, 512 KB
of HTML and 5 MB of image. The sender attaches the preview to the message
(`Cmux/HomeLinkSend`): a draft with URL-only lines waits for each card's
fetch (the one MessagesLab's send started; the local message already flies
with the grey card), then sends HomeStore parts in `TextParts` order,
`.text` blocks and `.linkPreview(url, title, site, image)`. The picture
(LinkPreviews' PNG) becomes a JPEG of at most 1024 px and 512 KB uploaded as
its own image record with the message (`HomeStore.prepareLinkPreviewImage`,
`send(conversation:parts:uploads:key:)`); the owner checks its hash like an
attachment's. A failed fetch sends the URL only (iMessage sends the bare
URL; every device shows the domain card). A receiver maps the part to
MessagesLab's card and loads only the picture, by hash, through HomeMedia
(`refreshAttachments` fills the card when it arrives), never the URL.

Messages' 434 pt window minimum (Host.swift) is not applied: a Home tab is a
pane in the cmux-next window, whose layout has one global minimum pane width
(`layout.minimumPaneWidth`) and no per-content minimum. A narrower pane scales
the text column (Layout patch above).

Host.swift is not vendored: 7f1a811's press and
hold, picker dim and Esc, double-click word and menu tapback rows are carried
in Cmux/PaneInteractions.swift and PaneHost, and 69f4256's menu (Tapback
Details…, Attach Sticker…, Share… for text and links), target highlight,
lifted bubble and the picker's emoji bubble in Cmux/PaneMenu.swift; cd2bc08's
attachment hover and at-once field growth (`onFieldJump`) in PaneHost. Not
offered in Home: Reply… (no reply op), Delete… (MessagesLab's `.delete`
hides a message on this device; HomeStore has no local hide and HomeOp no
delete), Edit and Undo Send. Threads never open in Home, so the thread
backdrop and 69f4256's thread Esc and outside-click handling are not wired.
For the
harness oracle, build MessagesLab from the pin with each pinned file overlaid. Then run the harness on cmux-lawrence-2
(`scripts/cmux-next/home-messageslab-harness.sh`, header): the Home path must
commit MessagesLab's animations byte for byte, and the vendored files must
match the upstream app's `--diff-harness` output.
