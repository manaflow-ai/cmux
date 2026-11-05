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
    tiles), LinkPreviews; `Resources/springs.json`; CrashGuard and
    CrashSafeGraphics (checked indexing, clamped conversions, named colour
    spaces and fonts with fallbacks; also vendored into MessagesLabSidebar)
    and HomeFonts (fonts the off-main row renderers share for the life of the
    process, at the exact size, at most 512 held).
  - appkit-port shim: UIKitNames, RoundedRect, LayerViews.
  - appkit-native: Compose, Materials, GlassKeyFix (b5742f3 compose-parity:
    Messages' key-window glass rims over the system glass; dark, 2x, macOS 27
    only), LabGlass (system glass on macOS 26
    and newer, an NSVisualEffectView stand-in on 14 and 15), NativeScroll,
    HeaderBar, HeaderBackdrop, TranscriptAccess, SwipeReply (installed only when the
    owner can take a reply: `ChatIntents.canReply`; Home sends the reply as
    `HomeOp.sendMessage(threadRoot:)`, the thread view's Esc and clicks are `Cmux/PaneHost+Thread.swift`),
    FlightRecorder (off until the app's policy, `HomeFlightRecorder`, turns it
    on: a Debug Settings opt-in in DEV and NIGHTLY until it costs at most 0.3 ms a
    frame, never Release or RC).
  - Not vendored (MessagesLab test drivers or app shell): App, Host, Bench,
    SelfTest, FlashCheck, AttachCheck, ResolutionAudit, LiveRecord,
    tools/diff-harness, PagedSource, Pager, HostHooksSelfTest.
  - Host hooks (b5742f3, MessagesLab host-hooks-a: asks 10 selection read,
    5 reveal and Copy Link, 8 Edit and Undo Send callbacks, 9 status line):
    `Vendor/catalyst/HostHooks.swift` is vendored and no `hostHooks` callback
    is set in Home. Home uses ask 9's status line for the Chief's live run
    (`HomeLiveLine` dispatches `.setNotice`); its own `cmuxNotice` row stays
    hidden while that line shows. A later landing adopts the other hooks (glue:
    PaneMenu, ChatController.clicked, HomeProjection id helpers). TranscriptAccess
    stays at bd65bbf, so its 1d45940 selection report (`noteHostFocus` from
    select/deselectBubble) is not in Home; the adopting landing calls
    `noteHostFocus` from the click glue.
  - Host hooks B (a293970, asks 1-4, 6, 7): `Vendor/catalyst/ThreadHost.swift`
    is vendored. Home runs the `.tree` thread mode (cx-och3h): `parent` is
    mapped, `replyCount` stays nil, and `demo.hostControl(at:)` is the first
    stop of the thread click path. Home sets no thread header hook: as in Messages,
    the thread view starts at its root bubble (cmux#26686); the daemon's thread
    object stays in Channels. Home sets no run-card row or sheet hook, so `sheetFrame` is always nil; the landing that presents a sheet
    must check it in the Esc and click paths (host-hooks-b-api.md).
  - Not ported from Host.swift: the live-resize bitmap keep (780934c,
    `MessagesWindowView.setLiveResizing`, `RowCell.liveResizing`). Home never
    sets the flag, so rows draw at every width in a window resize and a
    divider drag (decision hq-6d, 2026-10-14). The flag is one static per
    process, and Home has a window view per pane: one pane's resize end
    would redraw only its own kept rows.
- Per-view render scale (258b385, cx-3cb view-scale; our `appliedRenderScale`
  patch is gone): each pane's `MessagesWindowView` renders at its own
  `renderScale` (rows, masks, snaps, compose bar, header, morph, overlays,
  long-text tiles, text balloon widths). Home calls `setRenderScale` with the
  pane's `window.backingScaleFactor` when the pane goes into a window, when
  its window view is installed, when it is shown again and on every backing
  scale change (`Cmux/PaneHost+Scale.swift`, `followWindowScale`), never
  skipped by a compare with `Fixture.renderScale`. `ScaleKeeper` walks each
  pane's layer trees at that pane's `renderScale`.
  Key state per pane (806ef0c, in f79bdbe; cx-95476): each pane sets its own window view's
  inactive state from its own window (`Cmux/PaneHost+KeyState.swift`); the theme's bubbles use the key palette in both states. Known limits for Home's one-view-per-pane model (still process-wide
  upstream): `Fixture.lightAppearance` (one light/dark palette for every pane), `Metrics.current`,
  `LongTextCenter.handler` (the last view made gets the long-text height
  changes), `DisplayScale.colorSpace` (two displays of different colour
  spaces share one), and the display-change handler
  (`ChatController.followDisplay`, `Cmux/PaneHost+Scale.swift`, the Home
  handler rule from 1674e3f scale-redraw: in one
  `MessagesWindowView.displayChange` it sets `DisplayScale.colorSpace` and
  calls `displayColorSpaceChanged()` only when the space changed, then
  `setRenderScale(window.backingScaleFactor)`; never
  `RowBitmaps.shared.removeAll()`, never a `setInactive` toggle; cached bitmaps
  are keyed by scale and colour space. viewDidChangeBackingProperties and
  NSWindow.didChangeScreenNotification both call it; the second call finds
  nothing to do. Residual limit: a second pane on another display still
  changes the one process-wide colour space, and every pane's next row
  drawings use that space).
  Scale changes, both directions, one frame (2026-10-14, cmux-lawrence-2):
  after a move to 1x and back to 2x, no visible row shows a bitmap of the
  old scale one frame after the change (`scripts/cmux-next/home-scale-change.py`,
  the same rule both ways). Before the colour-space fix in 258b385 a move to
  1x kept the 2x bitmaps for up to 0.32 s: upstream `RowCell.configureScoped`
  (vendored Transcript.swift) keeps a shown row's bitmap on a repaint until
  the off-main `RowBitmaps.request` delivers, and the colour-space handler
  had emptied the cache.
- Soft copies (7924f00, cx-3cb soft-copies): a just-sent balloon keeps a
  crisp edge in flight and after it lands, and takes the soft edge when its
  status becomes delivered, read or failed (`MessagesWindowView.crispSends`,
  at most 64 rows). Home sends those statuses from HomeDiff
  (`HomeMapping.status`: a committed message with a sequence is delivered;
  a committed message without one stays `.sent`, so it stays crisp until its
  sequence comes). The context menu's highlight on my text balloon has the
  soft edge too (`Cmux/PaneMenu.swift` MenuHighlight, as Host.swift).
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
  `HomeFileCard` (a file attachment as a neutral card on either side, close to
  Messages': the type's system icon and localized kind, the name shortened in
  the middle with its extension kept; RowDrawing, Layout and `RowDraw.needsFill`
  hand file rows to it),
  `HomeVideo` (inline video: lane 16's `VideoPlayback` players placed in
  MessagesLab's video bubbles under the bubble mask, with RowDrawing's play
  disc while paused), `CmuxStrings` (Resources/CmuxHome.xcstrings),
  `HomeLinkPreviews` (which links may fetch a preview), `HomeLinkSend` (the
  preview a send attaches),
  `HomeDiagramRowProvider` (closed ```` ```mermaid ```` fences as drawn custom
  rows, `Part.custom` kind `cmux.mermaid`: sized by the injected
  `HomeDiagramRendering` before the image, a refused source stays text;
  `HomeMapping.parts` splits only while it is registered),
  `HomeMarkdown` (an agent's Markdown as MessagesLab text and style runs;
  people's text stays plain), `HomeFlightRecorder` (the flight recorder's
  policy, log folder and Save Last 10 Seconds, plus the helpers it calls from
  unvendored MessagesLab files),
  `FixtureTheme` (cmux theme to Fixture colours), `MessagesLabHomeView`
  (the public view).

## Blocker patches

Home activity is the Messages typing indicator: three staggered dots that pulse on the
render server inside a breathing bubble. Reduce Motion and the host's Home motion gate
(`MessagesLabHomeView.holdsTypingStill`) hold them still; ending typing and recycling a row
remove the loops. `MessagesLabHomeTests/TypingDotsTests` exercises the actual native Home view.


| file | why |
| --- | --- |
| Springs, Layout, TranscriptAccess, Model (fixture root) | resources live in the package bundle, not the app's main bundle |
| Model, Layout | live dates in the user's zone and locale (fixtures keep -07:00 and en_US) |
| Fixture, Transcript, Morph | optional cmux theme; nil keeps MessagesLab's measured palette |
| Fixture | a theme without an accent keeps MessagesLab's measured blue, gradient and white text (`FixtureTheme.measuredAccent`) |
| Fixture, Transcript, Compose | typing dots, placeholder, waveform, caret and chip fill from the theme on a light theme; a dark theme keeps MessagesLab's measured values (b5742f3: the placeholder and waveform are MessagesLab's see-through inks, `Fixture.placeholderInk`/`waveformInk`, also in `FixtureTheme`'s dark values) (da4161d: the typing indicator's fill is the theme's incoming grey, one level darker in red and green in the key window on a dark theme; its dots keep the measured dim and lit levels) (the field glass and its buttons follow with the view appearance, `FieldChrome.applyTheme`) |
| HeaderBackdrop | the tint uses the theme background (MessagesLab's grey read as a band on a cmux pane) |
| Layout, Localizable.xcstrings | the placeholder says Message, not iMessage; every string carries all 21 app languages (upstream has en and ja; the rest machine translated, `needs_review`) |
| AppKitNative.xcstrings | every string in all 21 app languages (machine translated, `needs_review`); `check-l10n.sh` scans this package's tables |
| Layout | a failed send that reached the owner unanswered says May Not Have Been Delivered (`CmuxStrings`, Resources/CmuxHome.xcstrings in every app language) |
| SwipeReply | the pane controller's window is optional |
| RowDrawing | file, audio, contact and voice memo rows on my side use the theme's sent text colour (white by default; a light accent showed white text) |
| Engine, WindowView | `cmuxSetAttachment`: an attachment part's picture or upload state changed in HomeStore (no content change, no transition; the row redraws in place) |
| Engine | `cmuxSetParticipants`: the participants again with new chosen avatars (each Chief's, `HomeProjection.senderAvatars`); the rows are derived again, so a group's bubbles follow a Chief avatar swap |
| Engine, Layout, Transcript | `cmuxNotice`: the host's notice (Home's merge notice) is MessagesLab's centered system row under the newest message, not an overlay; its accessibility label has no leading space. Its own state field (`ConversationUIState.cmuxNotice`, b5742f3: upstream's `notice` is ask 9's status line); row key `notice` (upstream's tail paging rules apply); not drawn while upstream's line is set |
| LabGlass | the macOS 14-15 glass stand-in stays active when Home's window is not key (Home keeps one look focused or not; `ChatController.followsKeyWindow`, `--follow-key-state` restores MessagesLab's inactive window view) |
| GlassKeyFix | the over-blend images are built by appending, not by index subscripts (crash ratchet: no new index_subscript hit in MessagesLabHome) |
| Compose, Transcript, SidebarDrawing (sidebar) | Reduce Motion (cx-sya4n: nothing loops): the caret holds solid, the typing dots stand at one phase and the typing bubble does not breathe (`MessagesLabHomeView.reduceMotionOverride` / `CmuxSidebarView.reduceMotionOverride`: cmux-next mirrors its `Motion.reduceMotionOverride`; nil reads the system setting). `startBlink` is not private, and a running pulse or breath stops in the still branches; the cmux hosts (`MessagesLabHomeView`, `CmuxSidebarView`) observe the system setting and the pins and re-apply them to loops already running |
| Compose | `onPastePasteboard`: the field's paste reaches the host's attachment intake first (Home's type rule, prepared by HomeStore) |
| Compose | `pasteTextBesideAttachments`: the words a taken paste carries beside its attachments go in at the caret; `writeSelection(to:types:)` with `draftAttachmentFile`: Copy, Cut and a drag of a selection holding attachments write the words without U+FFFC marks, then the files (`Cmux/ComposeSelectionCopy.swift`) |
| Layout | `code` runs draw monospaced with one font held for the process (`HomeFonts.code`: a font made per run on the row render threads came back nil and crashed) |
| LinkPreviews | the cache lives in the app's own caches folder (`<bundle id>/link-previews`), not MessagesLab's |
| ComposeAttachments | the image placeholder and file tile fill use the theme's chip fill on a light theme (a dark theme keeps the measured white) |
| Fixture | the gradient mix falls back to the measured blue when a colour cannot convert (never reads components of an unconverted colour; the Markdown getWhite fix is upstream as 40b9869) |
| SidebarView (sidebar) | Messages' pin drags (reorder a pinned tile, drag it onto the list to unpin, drag a row into the grid to pin it there, Escape cancels): the mouse-down hands off to `Cmux/SidebarPinDragging.swift`, a reload lets the drag follow or the drop land, and the tile layers, render context and avatar cache are readable by that file (the drag copies the drawn tile's parts, so it works on single-bitmap and layered tiles); upstream ask |
| SidebarView, SidebarModel, SidebarDrawing (sidebar) | Home's neutral selection (`CmuxSidebarView.neutralSelection`, the user 2026-10-18: no blue in the list): the selected row or pinned tile takes the unemphasized grey in every window state, its text keeps the label colour, an unselected pinned name is secondary grey (`SidebarPalette.pinName`), the unread dot and the bell/failed glyphs keep their colours. `roundFilterSide`: the host draws the filter button as a round button of that side with the plain filter glyph (Messages' toolbar buttons); nil keeps the 26 pt accessory button. `neutralFill`: the neutral selection's fill is the host's translucent theme tint (Leo 2026-10-19: not an opaque grey slab), and in the compact list the selected row or tile is a disc behind the avatar |
| SidebarDrawing (sidebar) | an emoji avatar (a Chief's 🫡) is centered on its disc by its drawn box, not its advance, at 60 % of the diameter on a tile and a row alike (`SidebarDraw.emoji`; set at half the disc it filled 47 % of the tile's and 52 % of the row's, the user 2026-10-20). 🫡's own art is cut at its right by the macOS 27 emoji font, whichever way it is drawn |
| SidebarView (sidebar) | `headerLayout`: the host lays out the header row (search, its own buttons) and says where the list starts (`CmuxSidebarView.layoutHeader`; Home's one-row header, `HomeSidebarHeaderLayout`); the search field is `CmuxSidebarSearchField`, which reports focus so the host draws its own ring and caret instead of AppKit's system blue |
| FlightRecorder | the app's policy and log folder (`HomeFlightRecorder`), window captures behind their own opt-in, the pane's optional window (attached from `ChatController.windowChanged`, observers replaced), FlashCheck/LiveProbes/Bench/LiveRecord helpers from `HomeFlightRecorder` |
| WindowView | a crisp send (7924f00 `crispSends`) also takes the soft edge when its message is delivered, read or failed in the new state, whatever the action (newest 256 messages read): Home sends one status per update (`HomeDiff.keepNewestStatus`) and a rebuild's `replaceWindow` carries statuses with no status action, so a send delivered together with a newer one, or in a rebuild, stayed crisp. Upstream ask (hq-34) |
| Layout | `MessagesLabLocalization`'s default is the package bundle (`Bundle(for:)` of a class in a linked package is the app's); the image placeholder and code-text strings carry all 21 app languages in Localizable.xcstrings |
| TranscriptAccess (pinned at bd65bbf) | MessagesLab 30495be's accessibility fix only: one element per visible message id, kept on `TranscriptSelection.axElements` and reused (an element made per call was freed, and VoiceOver and AX clients saw an empty Messages list); the rest of the newer file (selection menu, speech, search) is not rolled in. MessagesLab 2281879's selection outline is ported: the selected bubble's path is the drawn balloon (`RowDraw.balloon`, its frame's corners), with 267d218's half-circle ends of a 1-line text (`RowDraw.circularEnds`) |
| TranscriptAccess (drag selection) | the drag selection hit-tests and highlights through the row's drawn geometry (`PartRow.geometry(width:)`: MarkdownLayout, TextLayout or the long layout), not `PartRow.text`: a markdown row's `text` is a one-line proxy of its display string, so the highlight ran past the bubble and off the glyphs (scrawl 2026-10-18). Highlights are clipped to the bubble body; double-click words use the same geometry |
| Model, Layout, RowDrawing, Transcript | group chats show who sent each message, as iMessage (`Conversation.cmuxGroup`, set from CmuxHomeCore `ConversationSummary.kind(me:) == .group`): a `.senderName` row (11 pt, secondary) above the first bubble of each run of another person's messages, and that person's avatar (`Cmux/SenderAvatar.swift`: monogram disc, or the mapped picture) beside the run's last bubble. A group's incoming bubbles, and their thread connectors, sit `SenderAvatar.bubbleInset` right of the left edge (`PartRow.cmuxIndent`, `cmuxBodyX`). No name row above a reply that draws a connector. Direct and Chief chats are unchanged. Not indented yet: the typing bubble, thread previews and incoming Edited labels |
| SwipeReply, TranscriptAccess (own pins) | crash program (plans/cmux-next/crash-elimination.md): no force unwraps, `try!`, `as!` or IUOs. From eb1ed28 the rest of the crash program is upstream (586d5f0 CrashGuard/CrashSafeGraphics, ef7da0a the decided hunks), and so are the per-view widths, the 434 pt text column, the scroller's own right edge and the macOS 14 gates (60e79ec LabGlass) |
| LongText, TiledBubble, Selection | a folded long text lays out its head and tail from the measured line count through `LongTextFold.head`/`tailFirst`, which never form an inverted range: the fold is decided from the scan's estimate, and a measured total under 40 lines trapped in `TiledBody.update` (`Range requires lowerBound <= upperBound`, NIGHTLY 3952613909201, 2026-10-20). The folded selection's head range compares its clamped bounds (a visible top inside the last head line inverted it). Upstream ask |

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
that are wip checkpoints. Current pins (2026-10-20, imessage-parity): every file at 849eb3f except SwipeReply at 0c8147b and TranscriptAccess at bd65bbf (MessagesLab main f407606, the same vendored files as main 5946526: cdee8d9 + 08e0212's capture caret after a send, `Fixture.SendCaret`, ComposeView moves the capture caret with the placeholder; capture mode only, Home never sets it, and the measurement-only commits after it touch no vendored file). Each pane follows its own window's key state only with `--follow-key-state` (`ChatController.followsKeyWindow`): trunk's 283047940d8 rule stays, Home keeps the key look when its window is not key. Before that every file at f79bdbe except SwipeReply at 0c8147b and TranscriptAccess at bd65bbf (MessagesLab main cdee8d9 = a6c9d81 + the 2-line send width travel law, springs.json bubble.width.fieldShrinkMac2, refit in ce64461, and `Springs.bundle`: Home sets it to this package (HomeMarkdownPolicy.installSprings, from install() and the harness), so Springs.swift has no cmux patch; a6c9d81 = d7b2df6 + inactive state per window view: `Fixture.inactive` removed, `Fixture.typingColors(inactive:)`, `MessagesWindowView.setInactive` sets only its view; Home deletes its app-wide HomeKeyState: each pane follows its own window, PaneHost+KeyState.swift). Before that every file at d7b2df6 except SwipeReply at 0c8147b and TranscriptAccess at bd65bbf (MessagesLab main 537f76e = a293970 + ask 11, the streaming typing bubble: `.streamBegin`, `.streamSet`, `.streamAppend`, `.streamEnd(replacedBy:)`; the Engine and Layout patches were merged by hand: the cmux cases next to the stream cases, the cmux notice row before the stream-aware typing row). Home's Chief live text uses the stream actions (HomeProjection+Draft.swift). Before that every file at a293970 except SwipeReply at 0c8147b and TranscriptAccess at bd65bbf (bead cx-qor71, MessagesLab main 6d6497c, upstream lane cx-3cb: width-model2, macOS 27 only, the 3+ line field-shrink send width on one spring; host-hooks-b, asks 1-4, 6, 7: `ThreadHost.swift` (new row), tree thread mode, `openThread(path:)`, `hostControl(at:)`, thread header hooks, `DrawnRowProvider`, sheets; new strings label.replies.one, thread.back, thread.status.open/resolved, thread.owner.none in all 21 languages, machine translated beyond en/ja, `needs_review`). Home runs the `.tree` thread mode (cx-och3h: `ChatController.install` sets it; HomeMapping+Tree.swift maps the daemon's `reply_to` parent to `Message.parent`, `Message.replyCount` stays nil (counted from the loaded window); a send from a drilled branch goes out with `reply_to` = that message (HomeOp.sendMessage `parent`); PaneThread.clicked asks `hostControl(at:)` first; a permalink opens its message's branch, HomeProjection+Tree.swift). The thread header hooks and the run-card sheet are not set yet. Before that every file at b5742f3 (MessagesLab main 1d45940, cx-3cb: compose-parity, scale-redraw with the Home handler rule above, display-budget, header-parity, row-gap, spring-motion-curves, live-fixes landing fade, wide-window, host-hooks-a with every hook unset) except SwipeReply at 0c8147b and TranscriptAccess at bd65bbf; new rows HostHooks and GlassKeyFix. Before that every file at 7518134 (MessagesLab main 20108b1: `MessagesWindowView.tapbackInput`, a menu tapback's animations timed from the choosing input, `menuTapbackStart` 0.390 s; nil keeps the commit's time, which Home uses until PaneMenu passes its input; Host.swift's menu changes (choice fade, icon caches, warm-ups) are not ported yet). Before that every file at 8c25c3e (MessagesLab main 0430b25: reply arrival round 2, a thread root with its inline replies is separated like a sender change (32 pt), the rows above the root move on one 0.306 s curve, a long thread reply fades only its bubble. Home maps no thread yet (HomeMapping `replyTo: nil`), so Home does not take this path until it does). Before that every file at 9634112 (MessagesLab main 64af10f: the flight recorder writes a status without reflection. Not ported: LabWindow's typing cursor-rect hold (409694f, App.swift; Home's field is in the shared cmux window, so a window override needs hq-6d's OK) and ChatController.prefetchNextReceipt (64af10f, Host.swift)). Before that every file at 2a304f3 (MessagesLab main 1e256b6: reply arrival as Messages, a received text cross-fades with the typing bubble from the first frame (`received.textFade`, `typing.outOnReceive`), a received thread reply draws its connector first, then fades its bubble in (`connector.drawOnReceive`, `received.threadFade`), and the receive deferral holds only the rows whose fade waits; Home's `.receive` from HomeDiff takes it as is, and our WindowView hunk (`cmuxSetAttachment`) is not on the receive path). Before that every file at 9ca1b30 (MessagesLab main 8e81797: only App.swift and Host.swift changed, not vendored. Not called from cmux: `warmInputKeyBindings()`. It is safe only when no window and no local event monitor exists at the call, and cmux's applicationWillFinishLaunching is shared app-wide launch code where other lanes can add monitors or early windows at any time; the gain is 2 to 4 ms once). Before that every file at 147707f (MessagesLab main 7dcae12: only Host.swift changed, ChatController.warmKeyEventPath, which is not vendored and not ported: its Shift flagsChanged goes through NSApp.sendEvent to the first responder, a terminal surface sends it to the program as a key release). Before that every file at f4e1153 (MessagesLab main 44f00a4: 0ca9ae7, TextLayout.make measures with the drawn faces when a run has a style or a mention; our styled-run Layout hunk is gone). Before that every file at 1e011ac (the cmux-next pin of MessagesLab main 473ca57: compose round 2, the field changes height in one frame while typing up to Messages' 295.5 pt and scrolls the caret into view; the send phase split; fonts from HomeFonts or a static let, ccddf7c and a4304c3). Before that every file at eb1ed28 (upstream main eb1ed28: macOS 14 gates and LabGlass, CrashGuard/CrashSafeGraphics and HomeFonts upstream (our Cmux/ copies are gone; HomeFonts keeps the exact size, so the tapback glyphs no longer round to the half point), the tapback picker glass at the picker's bounds, the compose text in a scroll view past 8 lines, incoming bubbles, receipts and sidebar rows keep their bitmap across widths. Not ported: 8930efb's FrameSplitView rule, Home's split view is the app's). Before that every file at 92186cc (main 000a74c: during a send the compose tint stays over the bubble part still inside the field, bubble.opacity refit for macOS 27; a2e2fe0: the title pill re-centres on its accessory's layout. Not ported: a2e2fe0's FrameSplitView, the sidebar divider at most once per frame: Home's split view is the app's, not MessagesLab's window). Before that ced183d (main ac069b9: the palette follows the appearance (`Fixture.lightAppearance`; Home sets it and its theme from the cmux theme, a theme colour wins over the measured light or dark one), one transcript width pass per display frame in a divider drag or live resize (`widthFrameScheduler` on the pane's FrameTick), the field press light and release flash, the animated track-click page, row bitmaps kept across widths for width-invariant rows, Sidebar v1.2 (all six filters; `CmuxSidebarEntry` carries knownSender, spam and deletedAt, and a filter is offered only when the host names its source in `filterSources`: Home names none yet, HomeStore has no contact, spam or deletion state, so Home shows All Messages and Unread Messages; `movePinned` goes to the same placement as a pin drag; swipe actions; our pin drag stays, a superset of the tile reorder), the context menu as Host.swift draws it (`Cmux/MenuGlyphs.swift`: Messages.app's tapback art with the drawn glyphs as fallback, 20 pt palette images, fitted emoji and face sizes, item icons 11.7 pt medium, `sticker.badge.plus`; the highlight starts with the press and is committed before the menu's layout, incoming white 0.2; Esc starts its fade before AppKit's teardown, `PaneMenu.swift`). Not ported: the launch context-menu pre-warm (MessagesLab removes it too; `Cmux/PaneHost+FrameWiring.swift` says why), `HeaderBackdrop.setLight`: it sets Messages' tint (light white, dark 27.34 / 255 / 0.604 = 45 / 255), and Home's theme background is the cmux terminal theme's, equal to neither in general, so Home keeps `setTint(Fixture.background)`. Before that every file at 54bdedc (cd850a3 plus 2ecc9be's Xcode 26.3 build fix, 34faeea's send
motion without full-window masks, 8229d7e's opt-in Markdown per message (`Message.format`, plain by default:
HomeMapping marks an agent's text without mentions `.markdown`; our isPlain patch is gone) and one string bundle
(`MessagesLabLocalization`: Home's is the package bundle, a one-line Layout patch; the sidebar module has its own
`Cmux/SidebarLocalizationBundle.swift`), and 54bdedc's selection colour that follows the window key state; cd850a3 = 2579028 plus f6fa7f5's sidebar without hover: no hover layer,
tracking area or `palette.hover`, our `showsHover` patch gone; 403024c: a row keeps its old bitmap until the new one lands
during a live resize or divider drag, and the sidebar's accessibility frames from live geometry; cd850a3: MessagesLab's
Markdown security rule (`MarkdownLinkPolicy`: only http, https, mailto and `extraSchemes`, for Markdown, plain text, long
text and link cards, re-checked at click time; no image fetch, `MarkdownImages.provider` or "[Image: alt]"), our interim
link-policy patch gone. Home sets both before its first parse (`Cmux/HomeMarkdownPolicy.swift`: no extra scheme, images only
from HomeMedia's attachment pictures). verify-clean 5/5 with the crash ratchet. 2579028 = 285538d plus the LongText tail guard from our crash
ratchet; 285538d = 7d072dd plus 86c3cb3's sidebar row-text and pinned-dot fixes: those patches are gone), the sidebar's included
(7d072dd and c7b32bb, verified with verify-clean 5/5: the header avatar stays centred on the pill after a
resize, and ChromeView's `leadingEdgeIsWindowEdge`; Home hides ChromeView, so it keeps the default;
pinned tiles are layers and the unread dot sits below the unread bubble (`SidebarDraw.tileUnreadDot`); cc52c46, verified with MessagesLab's tools/verify-clean.sh 5/5: selection drags its text out, the
system text menu (Services) and media placeholders in a cross-bubble copy; long Markdown in tiles
(MarkdownLong.swift) and the off-main streaming tail, both OFF unless `--long-markdown` /
`--long-tail-off-main`; pinned sidebar tiles as separate layers; a copied attachment says
[File: name] in every app language. MessagesLab's custom-row host fixes (4dbf4e3) are in its
CustomRowsHost.swift, which this package does not vendor; 9ae05d5: the sidebar catalog in all 21 app languages, from cmux, upstream PR #2; 9e1f4a5: Sidebar
v1.1, strings from its own catalog in this package's bundle (`SidebarLocalization.bundle = .module`), optional menu actions, host menu items and search sections, injectable unread and
selection colours, and the updateHover fix (Tests/MessagesLabSidebarTests). 40b9869: MessagesLab's own fill span (the visible transcript plus one height above and
below, from the view's bounds; our fill-clamp patch is gone) and the Markdown colour fix
(our getWhite patch is gone); Sidebar v1.1's string catalog vendored as
MessagesLabSidebar/Resources/SidebarLocalizable.xcstrings ahead of its code. d5d6a18: Markdown rendering, the selection model, custom rows and their catalyst files
vendored; earlier bd65bbf: the applied contentOffset read back (no rounding drift), deferred spell checking
(SpellCheck.swift; its probe driver is compiled out), the scroller's track from under the
header to the field, send morph from the field top with a glass mask, Messages' interactions;
0e4eb90: Messages' own caret layer in the field and the typing-dot phase; 2ba9f72 moves rows with one container spring on the transcript's sublayer transform,
rows add only their difference (`--no-container-motion` for A/B); 995b723's cheaper
flight recorder (the cmux edits re-applied: policy, optional window, log folder);
85684b4 builds with Xcode 26.6 and 27 and keeps ScrollPrefetcher on the engine
clock; 02519e9 adds the light link card (#E9E9EB, `Fixture.lightAppearance` from the theme),
the outgoing-only LinkPresentation fallback (wired: `outgoingLinkOnScreen`,
`consider` on scroll, late answers fill the card), media fling paging inside the draw budget and recent emoji (`RecentEmoji`,
carried in Cmux/PaneInteractions.swift); earlier in this pin 89a1c5b, 2a0805d, 93cf61f,
bcfffae, 0fffbd2 and 48db8a7: long messages
collapse above 3 screens ("Show all N lines", EN and JA from upstream), header glass
and scroll indicator timing measured from Messages, resize anchoring like Messages, the
grey loading card and its fade-in, URLSession link previews through LinkGuard,
long text (LongText, TiledBubble, MediaCache), the scroller's knob drag and
track click, compose hover only over the field) except SwipeReply at 0c8147b and TranscriptAccess at bd65bbf (d5d6a18's rewrite needs
unvendored drivers: SelectionCheck, MarkdownAccess, the pager; a `cmux:` line speaks custom parts)
(installed when the owner can take a reply). Earlier in this pin: cd2bc08's link
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
