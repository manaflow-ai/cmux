public import CoreGraphics

/// The one set of numbers a pane's chrome lays out from (dogfood
/// 2026-10-01: "spacing above/below tab is not perfectly equal ... left
/// side of first tab and terminal main content border must align").
///
/// A pane's strip and content sit in its cell inset by the pane padding;
/// the content border starts where the strip ends. The tab pill gets one
/// gap, the same above it (from the cell's top edge, the window top for the
/// top row) and below it (to the content border):
///
///     gap = padding + pillTop      (above)
///     gap = strip - pillTop - tab  (below)
///
/// so `pillTop = (strip - tab - padding) / 2`, snapped down to the device
/// pixel grid, and the strip's height follows from it (the
/// `tabStripHeight` token, or one device pixel less when the token and a
/// custom padding cannot split evenly). Horizontally the first pill keeps
/// the same gap from the pane's leading edge as from its top (2026-10-19:
/// "the first tab, we need the same padding on the end and top"): the strip
/// insets its pills by `pillLeading`, which is `pillTop`, and the pane
/// padding outside the strip is the same on both sides. Outlined panes
/// (`outlinedContent`) keep the first pill on the outline's left line, the
/// line drawn right under it (2026-10-01). The terminal's first cell sits
/// `terminalTextInset` inside the border. Pure, so the rules are tested
/// with fixed numbers.
public nonisolated struct PaneChromeMetrics: Equatable, Sendable {
    /// The `tabStripHeight` token.
    public var stripHeight: CGFloat
    public var tabHeight: CGFloat
    /// The space above the strip that counts toward the gap above the pills:
    /// the pane padding between the cell and the strip, or 0 where the pane
    /// card's own edge is the strip's top (`Metrics.stripTopOutset`).
    public var panePadding: CGFloat
    /// Whether each pane draws an outline around its content (the `borders`
    /// separation): the first pill then starts on the outline's left line.
    public var outlinedContent: Bool

    public init(stripHeight: CGFloat, tabHeight: CGFloat, panePadding: CGFloat, outlinedContent: Bool = false) {
        self.stripHeight = stripHeight
        self.tabHeight = tabHeight
        self.panePadding = max(0, panePadding)
        self.outlinedContent = outlinedContent
    }

    /// Distance from the strip's leading (and trailing) edge to the first
    /// (and last) tab pill: the pill's own top inset, so the gap beside the
    /// first pill equals the gap above it in every window style; 0 for
    /// outlined panes, whose outline's left line the pill sits on.
    public func pillLeading(scale: CGFloat) -> CGFloat {
        outlinedContent ? 0 : pillTop(scale: scale)
    }

    /// Distance from the content border to the terminal's first cell on
    /// every side (Ghostty's `window-padding-x`/`-y` default in cmux; a
    /// user's own values win). 4 pt is one grid step past Ghostty's 2 pt:
    /// a full-cell glyph (cursor block, box drawing) keeps a visible gap from
    /// the one-pixel border, and the bottom row stays inside the rounded
    /// corner (compact radius 6). The grid's leftover goes to the right and
    /// bottom (no balance), so the left and top insets are exact.
    public static let terminalTextInset: CGFloat = 4 // Metrics.space2

    /// The pill's top inside the strip, on the device pixel grid of `scale`.
    public func pillTop(scale: CGFloat) -> CGFloat {
        let padding = Self.snap(panePadding, scale)
        return max(0, Self.snapDown((stripHeight - tabHeight - padding) / 2, scale))
    }

    /// The equal gap above and below the pill.
    public func tabGap(scale: CGFloat) -> CGFloat {
        Self.snap(panePadding, scale) + pillTop(scale: scale)
    }

    /// The strip's height: pill top + pill + gap below.
    public func resolvedStripHeight(scale: CGFloat) -> CGFloat {
        pillTop(scale: scale) + tabHeight + tabGap(scale: scale)
    }

    /// A top-row pill's top inside its strip, whose top edge is `stripTop` below the window's top
    /// edge (the card's top inset plus the pane padding): midway between the window's top edge and
    /// the strip's bottom (the divider under the row), so the gap above the pill equals the gap below
    /// it, as in every other row (#38054: moving the pill inside its strip to reach the traffic
    /// lights' line left 1 pt above it and 6 pt below at Comfortable). Never above the strip's top,
    /// never past its bottom, on `scale`'s pixel grid.
    public func pillTop(stripTop: CGFloat, scale: CGFloat) -> CGFloat {
        let room = stripHeight - tabHeight
        guard room > 0 else { return 0 }
        return min(max(0, Self.snapDown((room - max(0, stripTop)) / 2, scale)), room)
    }

    /// The top-row pill's center below the window's top edge with the card's top `cardTop` down
    /// (``pillTop(stripTop:scale:)``).
    public func topRowPillCenter(cardTop: CGFloat, scale: CGFloat) -> CGFloat {
        let stripTop = cardTop + Self.snap(panePadding, scale)
        return stripTop + pillTop(stripTop: stripTop, scale: scale) + tabHeight / 2
    }

    /// The card top, from the window's top edge, that puts the top row's pill center on `centerY`
    /// (the traffic lights' center line) with the pill's gaps above and below still equal
    /// (``pillTop(stripTop:scale:)``), so the tabs, the window buttons and the toolbar band share one
    /// line. The card only moves down: a line above the pill's center with the card at the window's
    /// top gives 0. On the pixel grid, the room left under the card splits evenly, so the center is
    /// within a device pixel of the line.
    public func cardTop(centeringPillOn centerY: CGFloat, scale: CGFloat) -> CGFloat {
        let padding = Self.snap(panePadding, scale)
        // With the card `c` down, the pill's center is (c + padding + stripHeight) / 2.
        let want = 2 * centerY - stripHeight - padding
        guard want > 0 else { return 0 }
        let room = stripHeight - tabHeight - padding
        // A pill that fills its strip has no gaps to even out: moving the card would only open one above it.
        guard room > 0 else { return 0 }
        let pill = Self.snapDown(min(max(0, (room - want) / 2), room / 2), scale)
        return room - 2 * pill
    }

    /// The card top that puts the pill's center on `centerY` with the pill kept at its own
    /// ``pillTop(scale:)`` in its strip: the top row before #38054, kept for Debug
    /// `chrome.topRowLine` off and for windows with no top-row strip (tab bars at the bottom).
    public func cardTopKeepingStripCentering(centeringPillOn centerY: CGFloat, scale: CGFloat) -> CGFloat {
        max(0, Self.snapDown(centerY - Self.snap(panePadding, scale) - pillTop(scale: scale) - tabHeight / 2, scale))
    }

    /// `cardTop` (on the pixel grid) moved one device pixel, down if `range` allows it, else up, when the
    /// room it leaves the pill is an odd number of pixels, so the pill's gaps above and below come out
    /// equal on a 1x display too (the window's rim or the gutter clamped the card there).
    public func evenSplitCardTop(_ cardTop: CGFloat, within range: ClosedRange<CGFloat>, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        let room = stripHeight - tabHeight - Self.snap(panePadding, scale) - cardTop
        guard room > 0, Int((room * s).rounded()) % 2 != 0 else { return cardTop }
        if cardTop + 1 / s <= range.upperBound { return cardTop + 1 / s }
        if cardTop - 1 / s >= range.lowerBound { return cardTop - 1 / s }
        return cardTop
    }

    /// The live tokens.
    @MainActor public static var current: PaneChromeMetrics {
        PaneChromeMetrics(stripHeight: Metrics.tabStripHeight, tabHeight: Metrics.tabHeight, panePadding: Metrics.stripTopOutset,
                          outlinedContent: Metrics.paneBorder != .none)
    }

    static func snap(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return (value * s).rounded() / s
    }

    static func snapDown(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return (value * s + 0.0001).rounded(.down) / s
    }
}
