# CmuxTabsKit upstream requests (from cmux-next-ios design/terminal)

For the owner of `feat-cmux-next-tabs-kit`. These come from the design pass in
[SPEC.md](SPEC.md) (P6, P7, M8, B1 point 5). cmux-next-ios does not patch
`Packages/iOS/CmuxTabsKit`; it stays byte-identical to the tabs-kit branch, and
every change lands there first (CmuxTabsKit sync rule).

Each request keeps today's behavior as the default, so existing clients build
and behave the same until they opt in. File and type names refer to
`Packages/iOS/CmuxTabsKit/Sources/CmuxTabsKit/` as synced at tabs-kit
`297a67c5`.

Not decided here: the grid zoom duration (about 240 ms). It is a pending user
decision. `video/v03-live-tab-open-from-grid.mp4` shows the zoom, but it ran at
load 101, so it is not a timing measurement. Nothing below changes it.

## U1. Active tab ring in the grid

**Today.** Neither grid marks the current tab. The active card looks like every
other card. See [img/03-tab-grid-mock-live.jpg](img/03-tab-grid-mock-live.jpg)
(mock left, live right) and [raw/L09-live-tab-grid.jpg](raw/L09-live-tab-grid.jpg).
The active card's live page is drawn by `TabsScreen.pageLayer` (`UI/TabsView.swift`);
the other cards by `TabCard` inside `TabOverview` (`UI/TabOverview.swift`).
`TabCard` adds `.isButton` only.

**Ask.** Draw a 3 pt accent ring outside the active card (Safari's grid), with
a 2 pt gap between card and ring, following the card's corner radius
(`OverviewLayout.cardRadius` + gap). It must ride the zoom: it fades out as the
active card zooms to the page and fades in when the grid settles. The active
card gets the `.isSelected` accessibility trait.

**Proposed API** (`API/TabsKitTheme.swift`):

```swift
extension TabsKitTheme.Metrics {
    /// Width of the ring around the active tab's card in the grid. 0 draws none.
    public var activeCardRing: CGFloat      // default 0 (today's look)
    /// Gap between the card and the ring.
    public var activeCardRingGap: CGFloat   // default 2
}
// The ring uses `TabsKitTheme.Colors.accent`.
```

The `.isSelected` trait on the active card is not themable; it should be on by
default (it is plain accessibility correctness). cmux-next-ios would set
`activeCardRing = 3`.

**Why.** After a zoom out, the user has to find the tab they came from. Safari
and Chrome both mark it. VoiceOver users today get no "selected" state at all.

**Host workaround meanwhile.** None. The card frame and the zoom live in the
kit; a host overlay would not follow the zoom or the grid scroll.

## U2. Card title style

**Today.** `TabCard` draws a 14 pt icon and a 15 pt semibold title, tail
truncation, in an `HStack` the width of the card. The mock grid reads
"Refactor transport l…" ([raw/d01-tabs-grid.jpg](raw/d01-tabs-grid.jpg)).
File-like titles lose their extension.

**Ask.** Footnote (13 pt) medium, centered under the card, one line. Middle
truncation for file-like titles (`report-2026-10-14.md` keeps `.md`), tail
truncation otherwise. Kind icon 12 pt, leading the title, centered as a group.

**Proposed API** (`API/TabsKitTab.swift`, `API/TabsKitTheme.swift`):

```swift
public struct TabsKitTab {
    /// How the card title truncates. Default `.tail`.
    public var titleTruncation: TabsKitTitleTruncation
}

public enum TabsKitTitleTruncation: Hashable, Sendable {
    case tail
    /// Keeps the end of the title visible (file names, paths).
    case middle
}

extension TabsKitTheme.Metrics {
    /// Card title font size and weight; default 15 / .semibold (today).
    public var cardTitleSize: CGFloat
    public var cardTitleWeight: Font.Weight
    /// Card title icon size; default 14 (today).
    public var cardTitleIconSize: CGFloat
}
```

`TabsKitTab.init` gains `titleTruncation: TabsKitTitleTruncation = .tail` as a
trailing defaulted parameter, so existing call sites compile. The centered
layout can be the default: today's `HStack` is already centered in a
card-width frame, so only the font and truncation change appearance.

**Why.** Safari uses footnote medium; 15 pt semibold crowds a 2-column grid on
a 402 pt phone, and tail truncation hides the part of a file name that tells
files apart.

**Host workaround meanwhile.** None. cmux-next-ios passes the title and SF Symbol
(`WorkspaceTabsSource.kitTab`) and cannot style the kit's title row.

## U3. Page chrome exposes only drawn controls

**Today** (accessibility tree of a terminal page, SPEC M8):

- `Button "Close zsh"` at (372, 0), 30 x 30, under the status bar: the active
  card's close button overlay in `TabsScreen.pageLayer` (`UI/TabsView.swift`,
  `.accessibilityLabel("Close \(activeTab?.title ?? "")")`). It is invisible on
  the page (opacity 0 when settled) but reachable by VoiceOver. Agent chat
  tabs have the same element, `Button "Close <session title>"` at (372, 0),
  30 x 30 (chat-feed round 1 review, F10).
- `Button "Page Menu"` at (90, 792) and `Button "Reload"` at (268, 792), inside
  the title pill (`TabsToolbar.capsule`, `UI/Toolbar.swift`). For a `.title`
  address `showsMenuGlyph` and `showsReload` are false, so neither is drawn,
  but both stay in the tree and their frames sit over the pill's ends.
- An empty `ScrollArea` at (90, 792), 48 x 82.

A likely cause: in each case `.accessibilityHidden(...)` comes before
`.accessibilityLabel(...)` and `.frame(...)`, and the later modifiers expose
the element again. When a control is not drawn it should be left out of the
hierarchy (`if showsReload { ... }`), not hidden with opacity.

See [raw/g01-title-menu.jpg](raw/g01-title-menu.jpg) (the pill and its menu)
and [img/07-title-menu-attach.jpg](img/07-title-menu-attach.jpg).

**Ask.**

1. Only drawn controls are accessible. The close overlay exists only in the
   overview phase; the page menu glyph and reload button exist only when
   `showsMenuGlyph` / `showsReload` are true.
2. For a `.title` address the pill is one button that opens the page menu (it
   already does) with no hit targets of hidden buttons over its ends.
3. Reload is opt-in through `TabsKitTabFeatures.reload`, as it is now; no
   change for web tabs (`.web` includes it). Terminal tabs never show it.

**Proposed API.** None new: this is a behavior fix inside `TabsView.swift` and
`Toolbar.swift`. Existing clients that rely on drawn controls see no change.

**Why.** Hidden buttons are announced by VoiceOver, steal taps at the pill's
ends, and confuse UI automation (the E2E rig finds "Close zsh" at y 0).

**Host workaround meanwhile.** None possible from the data source. cmux-next-ios
already omits `.reload` for terminal and agent tabs (`WorkspaceTabsSource.kitTab`).

**Round 5 (terminal review round 4, R4-3).** Still open in CmuxTabsKit
7808631e: the zoomed card's close button (`Close <tab>`, the page layer's
overlay) is in the accessibility tree while the page is settled. cmux-next-ios now
hides everything it draws while the page is not interactive
(`TerminalTabPage` with `isInteractive == false`, and the grid card content of
`TerminalTabCard`), so the thumbnails' live composer and key bar are no longer
announced; the close overlay itself can only be fixed in CmuxTabsKit.

## U4. Thumbnail anchoring hook

**Today.** On the settled grid the active tab's card is its live page, scaled
(`TabsScreen.pageLayer`: "its own card on the settled grid (live, following
the grid's scroll)"). Other cards come from `TabsDataSource.card(for:)`, laid
out by `ScaledContent` top-aligned. For a terminal the live page is drawn at
its current scroll position, bottom-anchored, so the card shows the session in
its last 10 % with blank rows above it
([raw/L09-live-tab-grid.jpg](raw/L09-live-tab-grid.jpg), right card;
[img/01-live-blank-rows-above.jpg](img/01-live-blank-rows-above.jpg)).

**Ask.** A data-source hook so a terminal tab's card in the grid (including
the active tab's, and the zooming card) is the client's own card view, a
snapshot from the terminal's top-anchored render, not the page at its current
scroll offset.

**Proposed API** (`API/TabsDataSource.swift`):

```swift
/// How the active tab is drawn while the grid is shown and during the zoom.
public enum TabsKitOverviewPresentation: Hashable, Sendable {
    /// The live page, scaled (today).
    case liveContent
    /// `card(for:)`, laid out like the other cards; the live page stays in
    /// the tree (never rebuilt) but is covered from zoom start until the
    /// page is settled full screen again.
    case card
}

public protocol TabsDataSource {
    /// Default `.liveContent`.
    func overviewPresentation(for id: TabsKitTab.ID) -> TabsKitOverviewPresentation
}
```

`overviewWillAppear()` stays the moment to refresh the card (cmux-next-ios takes the
terminal snapshot there, `GhosttyTerminalTabContent.overviewWillAppear`).

**Why.** SPEC B1 point 5: the thumbnail must use the same top-anchored layout
as the terminal. The kit's "one live view" rule is right for web pages; a
terminal has a better still of itself than its scrolled live view.

**Host workaround meanwhile.** cmux-next-ios already supplies terminal cards through
`card(for:)` (`TerminalTabCard`, a snapshot taken when the grid opens). That
covers every card except the active one. For the active card, the host-side
fix is B1 itself: once the terminal draws row 0 at the top, the live page and
its scaled card are both top-anchored. U4 is still wanted so the card can show
the top of the session while the page is scrolled to its end.

## U5. Title pill flashes light gray on first appearance over a dark page

**Seen:** on relaunch into a terminal tab, the page's title pill shows light gray for about 0.3 s, then settles
to the dark glass style. The host's own overlay (saved last frame, then live terminal) is already dark from the
first frame, so the flash is the pill's glass adapting to the page underneath on first appearance.
Evidence: terminal round 3 recordings (`/tmp/cmux-mobile-term-impl-tools/r3/`, relaunch strip), review REVIEW-round2.md R2-5.

**Ask:** let the host declare the page's initial appearance (e.g. `TabsPage.initialChromeStyle: .dark`), or have
the pill start from the page's declared `colorScheme`, so it never renders light over a dark terminal.

**Default:** unchanged (today's adaptive behavior) when the host declares nothing.

## U6. A compact notice toast that never covers the title or Back

**Today:** `TabsScreen` draws `source.notice` as a glass toast at the top of the page
(`UI/TabsView.swift`, `if let notice = source.notice`), at `safeTop + 8`, full width less 24 pt
margins, with no line limit. A long notice (a live user report: "Couldn't open a new Claude Chat on
Aziz's MacBook Pro: cwd is refused: a remote WebSocket connection may use only a known project or a
configured webRoots folder") wrapped to four lines over the workspace title and the Back button,
and stayed 5 s. cmux-next-ios now sends one short line (`TabNotice`) and clears it after 4 s, but the
placement still covers the page's top chrome while it shows.

**Ask:**

1. Place the toast where it covers no control: below the title pill / top bar, or just above the
   bottom toolbar (as Safari's and Photos' transient messages do).
2. Cap it at 2 lines (`lineLimit(2)`, tail truncation) and a compact size (footnote or subheadline).
3. Optional: let the host set the lifetime (`TabsDataSource.noticeLifetime`, default 5 s) and attach
   an optional "Details" action (`TabsKitNotice(text:details:)`), so a host can offer the technical
   reason without putting it in the toast.

**Default:** unchanged until a client opts in, or the new placement applies to every client if the
owner prefers (a notice over Back is never wanted).

## U7. No placeholder card until the client confirms the new tab

**Today:** in the grid, (+) → an option calls `newTabFromOverview`
(`UI/TabsView.swift`), which sets `pendingNewTab` at once: the grid lays out
`tabs.count + 1` cards with a placeholder slot, and every existing card reflows
(labels truncate and slide). When `createTab` returns `nil` (refused), the
placeholder is removed with the reflow animation, so the grid reshapes twice for
nothing. A live user report (build 38484, one tab, "New Claude Chat" refused by
the Mac's cwd policy) shows the existing card's label splitting into "Resp…" and
"…Chat" and the card ghosting before everything snaps back.

**Host workaround (cmux-next-ios, now):** `WorkspaceTabsSource.createTab` returns
`nil` at once and runs the request itself, showing "Opening a Claude chat…" in
the workspace screen; it activates the tab and leaves the grid only after the Mac
lists it. TabsKit's placeholder still exists for the instant between (+) and
that `nil`.

**Ask:**

1. Opt-in pending style: `TabsDataSource.newTabPendingStyle` = `.placeholderCard`
   (today's default) or `.button` (no grid change; (+) shows a spinner and is
   disabled until `createTab` returns).
2. With `.button`, a refused create (`nil`) changes nothing in the grid: no
   relayout, no label animation. A confirmed create zooms from the new card once
   it is in `tabs`.

**Default:** unchanged (`.placeholderCard`) for existing clients.

## U8. Hidden kit controls stay in the accessibility tree and take taps (T-TABS-14, verifier V3-4)

**Seen (round 3, rig AX dumps):**

- With a page settled full screen, the grid's `Close <tab>` button is still exposed.
- With the soft keyboard up, TabsKit's bottom toolbar buttons (Back, Page Menu,
  Reload, Tabs, at y 792) are exposed under the keyboard (keyboard top 566).
- A VoiceOver user can focus them, and a hit test can reach them.

mobile fixed its own copies in round 5. The zoomed page's composer, Return and Scroll to
bottom are now hidden from accessibility and hit-testing while
`TerminalTabContext.isInteractive` is false. The controls above are owned by the kit.

**Ask:**

1. While the page is settled (not zoomed out), the grid's cards and their close
   buttons are `accessibilityHidden` and do not take hits.
2. A toolbar covered by the keyboard is `accessibilityHidden(true)` and is not
   hit-testable, or it is laid out above the keyboard. Expose the keyboard frame
   the kit uses so that clients can agree with it.

**Default:** this is a correctness fix with no opt-in; nothing visible changes.

## Upstream changes synced 2026-10-14 (tabs-kit f085ad35 to 2dd83bab)

Context for terminal QA, not a request. cmux-next-ios synced CmuxTabsKit to
`2dd83bab` ("Safari parity re-audit 2 fixes"). No public API changed and no
host code changed. Behaviour to expect when testing close, new tab and the grid:

- **Swipe to close.** Release is judged on the card's position projected 0.2 s
  ahead at the release velocity (past 72% of the width, or a left fling faster
  than 225 pt/s). A drag that slows to a stop springs back; a slower swipe that
  leaves moving now closes where it used to spring back.
- **Close timing.** The kit calls `WorkspaceTabsSource.close(_:)` one frame
  (17 ms) after the release, not 99 ms. The fly-off is driven every display
  frame and stays above its neighbours. The host's close still awaits the Mac;
  a refusal (false) springs the card back with the notice, as before.
- **Long press.** A long-press reorder or menu owns the touch: dragging a card
  left in a reorder no longer closes it.
- **Closing the active card on the grid** fades and shrinks it instead of the
  live page vanishing in one frame.
- **Last tab closed.** The fresh tab grows sharp from the lone card's slot
  (0.375 / 0.98, at rest about 500 ms), not from 0.84 of the screen centre.
- **New tab** grows blurred and sharpens from the centre (0.27 / 1.03). Reflow
  after a close (0.43 / 0.865), zoom to page (0.356 / 0.99) and the bar
  swipe-up release speed were retuned.
