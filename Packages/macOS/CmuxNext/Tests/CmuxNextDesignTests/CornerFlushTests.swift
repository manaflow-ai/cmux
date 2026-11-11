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

    /// Both top wedges by default; the sidebar side's goes under `squareLeading`, on either side.
    @Test func theLeadingWedgeGoesWhenTheFirstTabIsSelected() {
        let card = CGRect(x: 100, y: 0, width: 400, height: 300) // unflipped: the top is maxY
        let topLeft = CGPoint(x: 100.5, y: 299.5), topRight = CGPoint(x: 499.5, y: 299.5)
        let both = CornerFlushChrome.wedgePath(card: card, radius: 12, squareLeading: false, sidebarOnLeft: true)
        #expect(both.contains(topLeft) && both.contains(topRight))
        #expect(!both.contains(CGPoint(x: 300, y: 299.5)))
        let left = CornerFlushChrome.wedgePath(card: card, radius: 12, squareLeading: true, sidebarOnLeft: true)
        #expect(!left.contains(topLeft) && left.contains(topRight))
        let right = CornerFlushChrome.wedgePath(card: card, radius: 12, squareLeading: true, sidebarOnLeft: false)
        #expect(right.contains(topLeft) && !right.contains(topRight))
    }
}

/// The goo value's fillets: only `flush-goo` draws them.
@MainActor @Suite struct CornerFlushGooTests {
    @Test func onlyGooHasFeet() {
        #expect(CornerFlush.goo.feetRadius > 0)
        for value in [CornerFlush.off, .flush, .tight] { #expect(value.feetRadius == 0) }
    }
}
