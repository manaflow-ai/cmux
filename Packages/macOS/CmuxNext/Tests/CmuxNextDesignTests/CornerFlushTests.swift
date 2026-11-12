import CoreGraphics
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The flush corner (`chrome.cornerFlush`, Thunderdome r2 A): the folder tab (`flush-goo`) by default, and the card's wedge on
/// the sidebar's side goes while the selected first tab rises from that corner.
@MainActor @Suite struct CornerFlushTests {
    /// Leo, 2026-11-10: the selected tab is the content's color, a folder tab, not a gray pill.
    @Test func gooIsTheDefault() {
        #expect(CornerFlush.tunable.defaultValue == .goo)
        #expect(CornerFlush.goo.isOn)
        #expect(!CornerFlush.off.isOn)
        #expect(CornerFlush.flush.isOn && CornerFlush.tight.isOn)
    }

    /// The default density (Default, the `cozy` preset) over the shipped chrome style draws the folder
    /// tab; compact density and a chrome the flush corner does not fit (floating panes) keep the pill.
    @Test func theDefaultChromeDrawsTheFolderTab() {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.chromeStyle)
        defer { (design.densityTokens, design.chromeStyle) = before }
        design.densityTokens = DensityPreset.cozy.tokens
        for style in [ChromeStyle.flat, .default] {
            design.chromeStyle = style
            #expect(CornerFlush.current == .goo, "\(style)")
        }
        design.chromeStyle = .floating
        #expect(CornerFlush.current == .off, "floating panes keep their cards")
        design.chromeStyle = .flat
        design.densityTokens = .compact
        #expect(CornerFlush.current == .off, "compact keeps the pill")
    }

    @Test func tightHasNoGapOnTheSidebarSide() {
        #expect(CornerFlush.tight.sidebarGap == 0)
        #expect(CornerFlush.flush.sidebarGap == CornerFlush.flush.gap)
        #expect(CornerFlush.off.sidebarGap == nil)
    }

    /// Both top wedges by default; the leading one (minX, where the first tab sits) goes under `squareLeading`.
    /// Tabs run from minX whichever side the sidebar is on, so there is no right-sidebar mirror: with the
    /// sidebar on the right the selected first tab's folder (no leading foot) used to land on the rounded
    /// wedge and end in a 12 pt shaded notch (Leo 2026-11-12, "all corners looking good").
    @Test func theLeadingWedgeGoesWhenTheFirstTabIsSelected() {
        let card = CGRect(x: 100, y: 0, width: 400, height: 300) // unflipped: the top is maxY
        let topLeft = CGPoint(x: 100.5, y: 299.5), topRight = CGPoint(x: 499.5, y: 299.5)
        let both = CornerFlushChrome.wedgePath(card: card, radius: 12, squareLeading: false)
        #expect(both.contains(topLeft) && both.contains(topRight))
        #expect(!both.contains(CGPoint(x: 300, y: 299.5)))
        let leading = CornerFlushChrome.wedgePath(card: card, radius: 12, squareLeading: true)
        #expect(!leading.contains(topLeft) && leading.contains(topRight))
    }

    /// The tab row's divider starts at the card's left edge under a squared leading corner and always stops
    /// short of the rounded trailing one.
    @Test func theDividerRunsFromTheSquaredLeadingCorner() {
        let card = CGRect(x: 100, y: 0, width: 400, height: 300)
        #expect(CornerFlushChrome.dividerLine(card: card, radius: 12, squareLeading: true) == CGRect(x: 100, y: 300, width: 388, height: 0))
        #expect(CornerFlushChrome.dividerLine(card: card, radius: 12, squareLeading: false) == CGRect(x: 112, y: 300, width: 376, height: 0))
    }

    /// A fullscreen window (no corner radius) keeps the windowed card: the titled window's radius less the
    /// frame's gap, at any interface scale and on either macOS window radius, so a fullscreen toggle reshapes
    /// no corner. It was a fixed 12 pt scaled, 6 pt windowed against 12 pt fullscreen on macOS 15.
    @Test func theFullscreenCardKeepsTheWindowedRadius() {
        let flush = CornerFlush.goo
        let windowed = max(0, Metrics.standardWindowCornerRadius - flush.gap)
        #expect(flush.cardRadius == windowed)
        #expect(Metrics.mainPaneCornerRadius(windowCornerRadius: 0) == Metrics.mainPaneCornerRadius(windowCornerRadius: Metrics.standardWindowCornerRadius)
                || !CornerFlush.current.isOn)
    }
}

/// The goo value's fillets: only `flush-goo` draws them.
@MainActor @Suite struct CornerFlushGooTests {
    @Test func onlyGooHasFeet() {
        #expect(CornerFlush.goo.feetRadius > 0)
        for value in [CornerFlush.off, .flush, .tight] { #expect(value.feetRadius == 0) }
    }
}
