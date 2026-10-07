import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// R109 `tabs.barPosition`: a pane's tab strip sits above (default) or
/// below its content. Below, the strip is the pane's footer: the content
/// starts at the pane's top and the border traces the content only.
@MainActor @Suite struct PaneTabBarPositionTests {
    private func pane(_ position: TabBarPosition) -> PaneContentView {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "nvim")], selectedID: TabID("t0"))
        let pane = PaneContentView(stripModel: model)
        pane.barPosition = position
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    @Test func topIsTheDefault() {
        let view = pane(.top)
        let strip = view.stripHeight
        #expect(view.stripView.frame.minY == 0 && view.contentHost.frame.minY == strip)
        #expect(view.paneHeaderHeight == strip && view.paneFooterHeight == 0)
    }

    @Test func bottomMakesTheStripTheFooter() {
        let view = pane(.bottom)
        let strip = view.stripHeight
        #expect(view.stripView.frame.maxY == 400 && view.stripView.frame.height == strip)
        #expect(view.contentHost.frame == NSRect(x: 0, y: 0, width: 600, height: 400 - strip))
        #expect(view.paneHeaderHeight == 0 && view.paneFooterHeight == strip)
    }

    @Test func aBrowserKeepsItsToolbarAsTheHeaderWithTheStripBelow() {
        let view = pane(.bottom)
        let chrome = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        view.show(chrome)
        view.layoutSubtreeIfNeeded()
        #expect(view.paneHeaderHeight == chrome.paneHeaderHeight && chrome.paneHeaderHeight > 0)
        #expect(view.paneFooterHeight == view.stripHeight)
    }

    @Test func aSwitchReportsTheNewChrome() {
        let view = pane(.top)
        var reports = 0
        view.onPaneHeaderHeightChange = { reports += 1 }
        view.barPosition = .bottom
        view.layoutSubtreeIfNeeded()
        #expect(reports >= 1)
        #expect(view.paneFooterHeight == view.stripHeight)
    }
}
