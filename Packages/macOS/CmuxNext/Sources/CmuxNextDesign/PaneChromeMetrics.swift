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
/// custom padding cannot split evenly). Horizontally the first pill starts
/// on the content border's left edge, and the terminal's first cell sits
/// `terminalTextInset` inside the border. Pure, so the rules are tested
/// with fixed numbers.
public nonisolated struct PaneChromeMetrics: Equatable, Sendable {
    /// The `tabStripHeight` token.
    public var stripHeight: CGFloat
    public var tabHeight: CGFloat
    /// The pane padding between the cell and the strip (and the border).
    public var panePadding: CGFloat

    public init(stripHeight: CGFloat, tabHeight: CGFloat, panePadding: CGFloat) {
        self.stripHeight = stripHeight
        self.tabHeight = tabHeight
        self.panePadding = max(0, panePadding)
    }

    /// Distance from the strip's leading edge to the first tab pill: the
    /// strip's leading edge is the content border's left edge.
    public static let pillLeading: CGFloat = 0

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

    /// The live tokens.
    @MainActor public static var current: PaneChromeMetrics {
        PaneChromeMetrics(stripHeight: Metrics.tabStripHeight, tabHeight: Metrics.tabHeight, panePadding: Metrics.panePadding)
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
