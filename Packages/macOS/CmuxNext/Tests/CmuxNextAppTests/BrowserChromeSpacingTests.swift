import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// R101 (Lawrence, 2026-10-04): "padding above tabbar needs to be identical
/// to padding between active tab/omnibar, which must be equal to padding
/// below omnibar." A browser pane is a tab strip over `BrowserChromeView`
/// (the same chrome for WebKit and Chromium tabs). Measured in pane points,
/// y down: the gap above the tab pill (pane padding + pill top), the gap
/// from the pill to the omnibar, and the gap from the omnibar to the page.
@MainActor
@Suite(.serialized)
struct BrowserChromeSpacingTests {
    private func gaps(width: CGFloat = 700) -> (above: CGFloat, tabToOmnibar: CGFloat, below: CGFloat) {
        let model = TabStripModel(tabs: [TabItem(id: TabID("b0"), title: "cmux")], selectedID: TabID("b0"))
        let pane = PaneContentView(stripModel: model)
        pane.frame = NSRect(x: 0, y: 0, width: width, height: 500)
        pane.layoutSubtreeIfNeeded()
        pane.stripView.sync(fromModel: true)
        pane.stripView.layoutSubtreeIfNeeded()
        pane.stripView.relayout(animated: false)
        let strip = pane.stripView
        let cell = strip.cells[TabID("b0")]!
        cell.layoutLayers()
        let pillTop = strip.tabsClip.convert(cell.frame.origin, to: pane).y + cell.pillFrameInCell.minY
        let pillBottom = pillTop + cell.pillFrameInCell.height

        // The chrome fills the content area under the strip.
        let chrome = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        chrome.frame = NSRect(x: 0, y: 0, width: width, height: 500 - strip.frame.maxY)
        chrome.layoutSubtreeIfNeeded()
        func topDown(_ rect: NSRect) -> (top: CGFloat, bottom: CGFloat) {
            chrome.isFlipped ? (rect.minY, rect.maxY) : (chrome.bounds.height - rect.maxY, chrome.bounds.height - rect.minY)
        }
        let bar = topDown(chrome.addressBar.convert(chrome.addressBar.bounds, to: chrome))
        let toolbar = topDown(chrome.toolbar.frame)
        let above = Metrics.panePadding + pillTop
        let tabToOmnibar = (strip.frame.maxY - pillBottom) + bar.top
        let below = toolbar.bottom - bar.bottom
        return (above, tabToOmnibar, below)
    }

    @Test(arguments: Density.allCases)
    func theThreeGapsAreEqual(density: Density) {
        let saved = DesignSettings.shared.density
        DesignSettings.shared.density = density
        defer { DesignSettings.shared.density = saved }
        let g = gaps()
        #expect(g.above == g.tabToOmnibar, "\(density): above \(g.above), tab to omnibar \(g.tabToOmnibar)")
        #expect(g.tabToOmnibar == g.below, "\(density): tab to omnibar \(g.tabToOmnibar), below \(g.below)")
        #expect(g.above > 0)
    }
}
