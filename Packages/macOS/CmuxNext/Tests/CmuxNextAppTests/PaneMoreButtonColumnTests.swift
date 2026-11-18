import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19627: "the three vertical dots, there are 2 of them, and they are different sizes".
/// A browser pane shows the tab bar's ⋮ (`PaneToolbarView`) above the toolbar's ⋮
/// (`BrowserToolbarButtonsView`, More). Both draw the app's one more glyph at one size, and their
/// glyphs share one column: the same distance from the pane's trailing edge.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneMoreButtonColumnTests {
    /// The browser toolbar's More: its center inset from the pane's trailing edge.
    private func toolbarMore() throws -> (button: ChromeIconButton, centerInset: CGFloat) {
        let row = BrowserToolbarButtonsView()
        let button = try #require(row.button(.overflow) as? ChromeIconButton)
        return (button, OmnibarStyle.toolbarTrailingInset + OmnibarStyle.buttonSize / 2)
    }

    @Test func bothMoreButtonsDrawOneGlyphAtOneSize() throws {
        let pane = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: Metrics.tabStripHeight))
        pane.show(more: true, lit: false)
        let (more, _) = try toolbarMore()
        #expect(more.iconName == OverflowButton.glyph, "the toolbar's More draws \(more.iconName), the tab bar's ⋮ \(OverflowButton.glyph)")
        let tabBar = try #require(pane.moreButton.image?.size)
        let toolbar = try #require(more.image?.size)
        #expect(tabBar == toolbar, "tab bar ⋮ \(tabBar), toolbar ⋮ \(toolbar)")
    }

    @Test func bothMoreButtonsShareOneTrailingColumn() throws {
        let width: CGFloat = 600
        let pane = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.tabStripHeight))
        pane.show(more: true, lit: false)
        pane.layoutSubtreeIfNeeded()
        let tabBarCenterInset = width - pane.moreButton.frame.midX
        let (_, toolbarCenterInset) = try toolbarMore()
        #expect(abs(tabBarCenterInset - toolbarCenterInset) < 0.5,
                "tab bar ⋮ center \(tabBarCenterInset) pt from the edge, toolbar ⋮ \(toolbarCenterInset) pt")
    }
}
