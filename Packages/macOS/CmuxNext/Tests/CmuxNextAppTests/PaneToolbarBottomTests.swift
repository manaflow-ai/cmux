import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// `browser.toolbarPosition` bottom in a pane (user, 2026-10-20: "move my OmniBar tabs to the
/// bottom side"): the pane hands the setting to its browser, and with the tab bar on the same edge
/// `tabs.barOrder` stacks the two. Rects are in window coordinates (y up).
@MainActor @Suite(.serialized) struct PaneToolbarBottomTests {
    struct Pane {
        let window: NSWindow
        let pane: PaneContentView
        let chrome: BrowserChromeView
        let page: WebKitTab

        init(tabBar: TabBarPosition, toolbar: ToolbarPosition, order: TabBarOrder) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("browser"), title: "Example")]),
                                   reveal: LaunchReveal(deadline: .zero))
            pane.barPosition = tabBar
            pane.barOrder = order
            pane.toolbarPosition = toolbar
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: page)
            pane.show(chrome)
            pane.layoutSubtreeIfNeeded()
        }

        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        var strip: NSRect { rect(pane.stripView) }
        var toolbar: NSRect { rect(chrome.toolbar) }
        var pageArea: NSRect { rect(chrome.contentContainer) }

        func tearDown() {
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    @Test func thePaneHandsThePositionToItsBrowser() {
        let tab = Pane(tabBar: .top, toolbar: .bottom, order: .aboveToolbar)
        defer { tab.tearDown() }
        #expect(tab.chrome.toolbarPosition == .bottom, "the browser shown in the pane takes it")
        tab.pane.toolbarPosition = .top
        #expect(tab.chrome.toolbarPosition == .top, "a change reaches the browser on screen")
    }

    @Test func tabBarOnTopToolbarAtTheBottom() {
        let tab = Pane(tabBar: .top, toolbar: .bottom, order: .belowToolbar)
        defer { tab.tearDown() }
        let all = tab.rect(tab.pane)
        #expect(tab.strip.maxY == all.maxY, "the strip stays the pane's top row")
        #expect(tab.toolbar.minY == all.minY, "the toolbar is the pane's bottom row")
        #expect(tab.pageArea.maxY <= tab.strip.minY && tab.pageArea.minY >= tab.toolbar.maxY)
        #expect(!tab.pane.isBandActive, "opposite edges: tabs.barOrder has nothing to order")
    }

    /// Both at the bottom, tab bar above: page, tab strip, toolbar.
    @Test func bothAtTheBottomTabBarAboveTheToolbar() {
        let tab = Pane(tabBar: .bottom, toolbar: .bottom, order: .aboveToolbar)
        defer { tab.tearDown() }
        let all = tab.rect(tab.pane)
        #expect(tab.pane.isBandActive, "the strip sits in the browser's band between page and toolbar")
        #expect(tab.toolbar.minY == all.minY)
        #expect(abs(tab.strip.minY - tab.toolbar.maxY) < 0.5 && tab.strip.height > 0)
        #expect(tab.pageArea.minY >= tab.strip.maxY - 0.5)
        #expect(tab.pane.paneFooterHeight == 0, "the strip is inside the content area, as the toolbar is")
    }

    /// Both at the bottom, tab bar below: page, toolbar, tab strip.
    @Test func bothAtTheBottomTabBarBelowTheToolbar() {
        let tab = Pane(tabBar: .bottom, toolbar: .bottom, order: .belowToolbar)
        defer { tab.tearDown() }
        let all = tab.rect(tab.pane)
        #expect(!tab.pane.isBandActive)
        #expect(tab.strip.minY == all.minY, "the strip is the pane's footer")
        #expect(abs(tab.toolbar.minY - tab.strip.maxY) < 0.5, "the toolbar right above the strip")
        #expect(tab.pageArea.minY >= tab.toolbar.maxY)
    }

    /// A Markdown tab (a page with a native bar): the bar moves under the page.
    @Test func aPagesBarMovesUnderThePage() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let bar = NSView()
        bar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let content = NSView()
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("md"), title: "README.md")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.toolbarPosition = .bottom
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let view = InternalPageView(key: "md", page: .homeTab, content: content, topBar: bar)
        pane.show(view)
        pane.layoutSubtreeIfNeeded()
        let barRect = bar.convert(bar.bounds, to: nil), contentRect = content.convert(content.bounds, to: nil)
        #expect(view.toolbarPosition == .bottom)
        #expect(barRect.minY == view.convert(view.bounds, to: nil).minY, "the bar is the page tab's bottom row")
        #expect(contentRect.minY == barRect.maxY)
        #expect(bar.toolbarOpensUpward)
    }
}
