import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// R109 `tabs.barOrder` below the toolbar: a browser pane opens a band under
/// its toolbar and the strip pins to it (`PaneHeaderBandHosting`). The pins
/// end before the browser view leaves the pane on every path, and VoiceOver
/// reads toolbar, strip, page.
@MainActor @Suite(.serialized) struct PaneTabBarBandTests {
    private struct Fixture {
        let window: NSWindow
        let pane: PaneContentView
        let chrome: BrowserChromeView
    }

    private func fixture(order: TabBarOrder = .belowToolbar) -> Fixture {
        let model = TabStripModel(tabs: [TabItem(id: TabID("b0"), title: "cmux")], selectedID: TabID("b0"))
        let pane = PaneContentView(stripModel: model)
        pane.barPosition = .top
        pane.barOrder = order
        // Never ordered front: the window only gives the views one tree.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = pane
        let chrome = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        pane.show(chrome)
        pane.layoutSubtreeIfNeeded()
        return Fixture(window: window, pane: pane, chrome: chrome)
    }

    @Test func theStripSitsInTheBandUnderTheToolbar() {
        let f = fixture()
        let band = f.chrome.convert(f.chrome.paneHeaderBandRect, to: f.pane)
        #expect(f.pane.isBandActive)
        #expect(band.height == f.pane.stripHeight)
        #expect(abs(f.pane.stripView.frame.minY - band.minY) < 0.5 && f.pane.stripView.frame.height == band.height)
        #expect(f.pane.contentHost.frame.minY == 0 && f.pane.contentHost.frame.height == 500)
        #expect(f.pane.paneHeaderHeight == f.chrome.paneHeaderHeight && f.pane.paneFooterHeight == 0)
    }

    @Test func aboveTheToolbarKeepsTheStripOnTop() {
        let f = fixture(order: .aboveToolbar)
        #expect(!f.pane.isBandActive && f.chrome.paneHeaderBandRect.height == 0)
        #expect(f.pane.stripView.frame.minY == 0 && f.pane.contentHost.frame.minY == f.pane.stripHeight)
    }

    @Test func removingTheBrowserDirectlyReleasesThePins() {
        let f = fixture()
        f.chrome.removeFromSuperview()
        #expect(!f.pane.isBandActive)
        f.pane.layoutSubtreeIfNeeded()
        #expect(f.pane.stripView.frame.minY == 0)
    }

    @Test func aTabSwitchReleasesThePinsAndClosesTheBand() {
        let f = fixture()
        f.pane.show(NSView())
        f.pane.layoutSubtreeIfNeeded()
        #expect(!f.pane.isBandActive && f.chrome.paneHeaderBandRect.height == 0)
        #expect(f.pane.stripView.frame.minY == 0)
    }

    @Test func voiceOverReadsToolbarStripPageAndForgetsTheOrderWhenTheBandEnds() throws {
        let f = fixture()
        let children = try #require(f.pane.accessibilityChildren())
        let strip = try #require(children.firstIndex { ($0 as AnyObject) === f.pane.stripView })
        let toolbar = try #require(children.firstIndex { ($0 as AnyObject) === f.chrome.toolbar })
        let page = try #require(children.firstIndex { ($0 as AnyObject) === f.chrome.contentContainer })
        #expect(toolbar < strip && strip < page)
        f.pane.barOrder = .aboveToolbar
        f.pane.layoutSubtreeIfNeeded()
        let after = f.pane.accessibilityChildren() ?? []
        #expect(!after.contains { ($0 as AnyObject) === f.chrome.toolbar }, "the default order: the pane's own subviews")
    }
}
