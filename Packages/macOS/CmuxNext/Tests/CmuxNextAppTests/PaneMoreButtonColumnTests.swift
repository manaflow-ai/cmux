import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19627: "the three vertical dots, there are 2 of them, and they are different sizes".
/// A browser pane shows the tab bar's ⋮ (`PaneToolbarView`) above the toolbar's ⋮ (More, drawn by
/// the toolbar page from `BrowserToolbarButtons`). Both draw the app's one more glyph, and their
/// glyphs share one column: the same distance from the pane's trailing edge (the page places More
/// at `ToolbarRowMetrics.toolbarTrailingInset`).
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneMoreButtonColumnTests {
    @Test func bothMoreButtonsDrawOneGlyph() {
        let facts = BrowserToolbarFacts(engine: .webkit, hostsDevTools: false)
        #expect(BrowserToolbarPolicy.state(.overflow, facts, shortcut: nil).icon == OverflowButton.glyph)
    }

    @Test func bothMoreButtonsShareOneTrailingColumn() {
        let width: CGFloat = 600
        let pane = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.tabStripHeight))
        pane.show(more: true, lit: false)
        pane.layoutSubtreeIfNeeded()
        let tabBarCenterInset = width - pane.moreButton.frame.midX
        let toolbarCenterInset = ToolbarRowMetrics.toolbarTrailingInset + ToolbarRowMetrics.buttonSize / 2
        #expect(abs(tabBarCenterInset - toolbarCenterInset) < 0.5,
                "tab bar ⋮ center \(tabBarCenterInset) pt from the edge, toolbar ⋮ \(toolbarCenterInset) pt")
    }
}
