import CoreGraphics
@testable import CmuxNextDesign
import CmuxNextDesignTokens
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

    /// The default folder tab applies to the default window (`appearance.chromeStyle` unset reads as
    /// `flat`) and to every style with the card; a style the user picked without the card keeps its
    /// layout and its gray selection.
    @Test func theDefaultKeepsAPickedLayoutWithoutTheCard() {
        guard CornerFlush.tunable.override == nil, ChromeTunables.mainPaneCurved.override == nil,
              DesignSettings.shared.paneChrome.padding == nil else { return }
        let design = DesignSettings.shared
        let before = design.chromeStyle
        defer { design.chromeStyle = before }
        for style in [ChromeStyle.default, .flat, .card, .floating] {
            design.chromeStyle = style
            #expect(CornerFlush.current == .goo, "\(style) takes the folder tab")
        }
        for style in [ChromeStyle.bare, .panes, .flatSidebarLine] {
            design.chromeStyle = style
            #expect(CornerFlush.current == .off, "\(style) keeps its layout")
        }
    }

    /// The folder join leaves a layout's geometry alone: Floating Panes and Blocks, each pane its own
    /// card, keep their pane padding under the folder tab (Codex at 922f9ad0, F1).
    @Test func floatingAndBlocksKeepTheirPanePadding() {
        guard CornerFlush.tunable.override == nil, ChromeTunables.mainPaneCurved.override == nil,
              DesignSettings.shared.paneChrome.padding == nil else { return }
        let design = DesignSettings.shared
        let before = design.chromeStyle
        defer { design.chromeStyle = before }
        for style in [ChromeStyle.floating, .blocks] {
            design.chromeStyle = style
            guard CornerFlush.current.isOn else { continue }
            #expect(Metrics.codePanePadding == Metrics.densityPanePadding, "\(style) keeps its pane padding")
        }
        design.chromeStyle = .flat
        #expect(Metrics.codePanePadding == 0, "the flat card's first tab starts on the card's edge")
    }

    /// `layout.paneCornerRadius` 0: the frame still shades the chrome and cuts the folder holes, with a
    /// square join (no wedges), so the selected tab keeps its surface (Codex at 2b1e6839, F1).
    @Test func aSquareCardStillDrawsTheFrame() {
        #expect(CornerFlushChrome.drawsFrame(on: true, alpha: 0.28, radius: 0, floating: false))
        #expect(CornerFlushChrome.drawsFrame(on: true, alpha: 0.28, radius: 12, floating: false))
        #expect(!CornerFlushChrome.drawsFrame(on: true, alpha: 0, radius: 0, floating: false))
        #expect(!CornerFlushChrome.drawsFrame(on: false, alpha: 0.28, radius: 12, floating: false))
        // Floating Panes and Blocks (radius 0, each pane its own card) keep out of the trimmed frame (Codex at 0f2ac599, F2).
        #expect(!CornerFlushChrome.drawsFrame(on: true, alpha: 0.28, radius: 0, floating: true))
        let card = CGRect(x: 100, y: 0, width: 400, height: 300)
        #expect(CornerFlushChrome.wedgePath(card: card, radius: 0, squareLeading: false, sidebarOnLeft: true).isEmpty)
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
