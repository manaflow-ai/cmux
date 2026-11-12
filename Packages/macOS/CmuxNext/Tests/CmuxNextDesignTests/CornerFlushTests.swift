import CoreGraphics
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The flush corner (`chrome.cornerFlush`, Thunderdome r2 A): the pill (`off`) by default, the folder tab (`flush-goo`)
/// when picked, and the card's wedge on the sidebar's side goes while the selected first tab rises from that corner.
@MainActor @Suite struct CornerFlushTests {
    /// Lawrence, 2026-11-12: the folder tab is not the default; the pill is.
    @Test func offIsTheDefault() {
        #expect(CornerFlush.tunable.defaultValue == .off)
        #expect(CornerFlush.goo.isOn)
        #expect(!CornerFlush.off.isOn)
        #expect(CornerFlush.flush.isOn && CornerFlush.tight.isOn)
    }

    /// The default density (Default, the `cozy` preset) over the shipped chrome style draws the pill; a Debug
    /// pick of `flush-goo` draws the folder tab, and compact density keeps the pill under that pick too.
    @Test func theDefaultChromeDrawsThePillUntilTheFolderTabIsPicked() {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.chromeStyle)
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        defer {
            (design.densityTokens, design.chromeStyle) = before
            store.set(CornerFlush.tunable.key, nil)
        }
        design.densityTokens = DensityPreset.cozy.tokens
        for style in [ChromeStyle.flat, .default] {
            design.chromeStyle = style
            #expect(CornerFlush.current == .off, "\(style)")
        }
        store.set(CornerFlush.tunable.key, .choice(CornerFlush.goo.rawValue))
        #expect(CornerFlush.current == .goo, "a Debug pick draws the folder tab")
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
