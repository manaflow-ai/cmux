import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The flush corner (`chrome.cornerFlush`, Thunderdome r2 A): the folder tab (`flush-goo`) by default
/// (design/selected-is-foreground.md), and the card's wedge on
/// the sidebar's side goes while the selected first tab rises from that corner.
@MainActor @Suite struct CornerFlushTests {
    @Test func theFolderTabIsTheDefault() {
        #expect(CornerFlush.tunable.defaultValue == .goo)
        #expect(!CornerFlush.off.isOn)
        #expect(CornerFlush.flush.isOn && CornerFlush.tight.isOn)
    }

    /// The default folder tab keeps the layout the user chose: a chrome style without the curved main
    /// pane keeps it off (and its gray selection); one with the card takes it.
    @Test func theDefaultKeepsAFlatChromeStyle() {
        guard CornerFlush.tunable.override == nil, DesignSettings.shared.paneChrome.padding == nil else { return }
        let design = DesignSettings.shared
        let before = design.chromeStyle
        defer { design.chromeStyle = before }
        design.chromeStyle = .flat
        #expect(CornerFlush.current == .off, "a flat window keeps its layout")
        design.chromeStyle = .card
        #expect(CornerFlush.current == .goo, "the card takes the folder tab")
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
