import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19627: "the three vertical dots, there are 2 of them, and they are different sizes".
/// The tab bar's trailing button (`PaneToolbarView`: a pin or Exit Zoom; its "…" is gone, user 2026-11-13)
/// sits above the browser toolbar's ⋮ (`BrowserToolbarButtonsView`, More) in one column: the same
/// distance from the pane's trailing edge.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneMoreButtonColumnTests {
    @Test func theTabBarsTrailingButtonSharesTheToolbarMoreColumn() throws {
        let width: CGFloat = 600
        let pane = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.tabStripHeight))
        pane.show(zoomed: true)
        pane.layoutSubtreeIfNeeded()
        let tabBarCenterInset = width - pane.zoomButton.frame.midX
        let toolbarCenterInset = OmnibarStyle.toolbarTrailingInset + OmnibarStyle.buttonSize / 2
        #expect(abs(tabBarCenterInset - toolbarCenterInset) < 0.5,
                "tab bar's trailing button center \(tabBarCenterInset) pt from the edge, toolbar ⋮ \(toolbarCenterInset) pt")
    }
}
