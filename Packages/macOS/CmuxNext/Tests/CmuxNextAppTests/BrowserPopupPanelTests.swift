import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import Testing

/// Sized popups (OAuth, payment, extension popup windows) open in a small
/// floating panel over the opener's window: placed on the opener's screen,
/// closed by `window.close()`, an unhandled Escape, or the opener window
/// closing; never a daemon tab.
@MainActor
@Suite struct BrowserPopupPanelTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private static let opener = CGRect(x: 200, y: 100, width: 1000, height: 700)

    private func frame(_ request: BrowserPopupRequest, opener: CGRect = opener, visible: CGRect = screen) -> CGRect {
        BrowserPopupPanelGeometry.frame(for: request, opener: opener, visibleFrame: visible, primaryHeight: 900, titleHeight: 28)
    }

    /// The page's size is the content size; the panel adds its title bar and
    /// centers over the opener when the page gave no position.
    @Test func sizedPopupCentersOverTheOpener() {
        let result = frame(BrowserPopupRequest(size: CGSize(width: 480, height: 640)))
        #expect(result.size == CGSize(width: 480, height: 668))
        #expect(result.midX == Self.opener.midX)
        #expect(result.midY == Self.opener.midY)
    }

    /// A position on the opener's screen is honored (screen points from the
    /// top-left of the primary display).
    @Test func positionOnTheScreenIsHonored() {
        let result = frame(BrowserPopupRequest(size: CGSize(width: 400, height: 300), origin: CGPoint(x: 100, y: 50)))
        #expect(result.minX == 100)
        #expect(abs(result.maxY - 850) < 0.001)
    }

    /// A position off the opener's screen (another display, or a page that
    /// asks for -9999) centers over the opener instead.
    @Test func positionOffTheScreenCentersOverTheOpener() {
        let result = frame(BrowserPopupRequest(size: CGSize(width: 400, height: 300), origin: CGPoint(x: -5000, y: 50)))
        #expect(result.midX == Self.opener.midX)
    }

    /// A page cannot make the panel larger than the screen or tiny.
    @Test func sizeIsClampedToTheScreen() {
        let huge = frame(BrowserPopupRequest(size: CGSize(width: 9000, height: 9000)))
        #expect(Self.screen.contains(huge))
        let tiny = frame(BrowserPopupRequest(size: CGSize(width: 10, height: 10)))
        #expect(tiny.width >= BrowserPopupPanelGeometry.minimumContent.width)
        #expect(tiny.height >= BrowserPopupPanelGeometry.minimumContent.height + 28)
    }

    /// No size (an extension's popup window): a default size, inside the screen.
    @Test func missingSizeUsesTheDefault() {
        let result = frame(BrowserPopupRequest())
        #expect(result.width == BrowserPopupPanelGeometry.defaultContent.width)
        #expect(Self.screen.contains(result))
    }

    private func makeParent() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: Self.opener, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func makePage() -> MockBrowserTab {
        MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/auth")))
    }

    /// The panel is a child of the opener's window, so it moves and hides
    /// with it and stays above it.
    @Test func thePanelIsAChildOfTheOpenerWindow() throws {
        let panels = BrowserPopupPanels()
        panels.ordersPanelsIn = false
        let parent = makeParent()
        let page = makePage()
        panels.open(page, request: BrowserPopupRequest(size: CGSize(width: 480, height: 640)), over: parent, openerKey: "tab-1")
        let panel = try #require(panels.panel(for: page))
        #expect(parent.childWindows?.contains(panel) == true)
        #expect(panels.openerKey(of: page) == "tab-1")
        #expect(panels.owns(page))
        panels.closeAll()
    }

    /// `window.close()` in the popup closes the panel and the page.
    @Test func windowCloseClosesThePanel() {
        let panels = BrowserPopupPanels()
        panels.ordersPanelsIn = false
        let parent = makeParent()
        let page = makePage()
        panels.open(page, request: BrowserPopupRequest(), over: parent, openerKey: "tab-1")
        #expect(panels.handle(page, .close))
        #expect(!panels.owns(page))
        #expect(page.isClosed)
        #expect(parent.childWindows?.isEmpty ?? true)
    }

    /// Escape the page did not use closes the panel.
    @Test func unhandledEscapeClosesThePanel() {
        let panels = BrowserPopupPanels()
        panels.ordersPanelsIn = false
        let page = makePage()
        panels.open(page, request: BrowserPopupRequest(), over: makeParent(), openerKey: "tab-1")
        #expect(panels.handle(page, .unhandledEscape))
        #expect(!panels.owns(page))
        #expect(page.isClosed)
    }

    /// Closing the opener's window closes its popups (no orphan panel, no
    /// page left running).
    @Test func closingTheOpenerWindowClosesItsPopups() {
        let panels = BrowserPopupPanels()
        panels.ordersPanelsIn = false
        let parent = makeParent()
        let page = makePage()
        panels.open(page, request: BrowserPopupRequest(), over: parent, openerKey: "tab-1")
        parent.close()
        #expect(!panels.owns(page))
        #expect(page.isClosed)
    }

    /// An extension's popup window (`chrome.windows.update` with bounds):
    /// the panel takes the new content size and keeps its title bar.
    @Test(.requiresGUISession) func resizePopupResizesThePanel() throws {
        let panels = BrowserPopupPanels()
        panels.ordersPanelsIn = false
        let parent = makeParent()
        let page = makePage()
        panels.open(page, request: BrowserPopupRequest(size: CGSize(width: 400, height: 300)), over: parent, openerKey: "tab-1")
        let panel = try #require(panels.panel(for: page))
        let before = panel.frame
        #expect(panels.handle(page, .resizePopup(BrowserPopupRequest(size: CGSize(width: 600, height: 500)))))
        #expect(panel.frame.width == 600)
        #expect(panel.frame.height == 500 + (before.height - 300))
        #expect(panels.owns(page), "a resize never closes the panel")
        panels.closeAll()
    }

    /// A page that is not in a panel is not handled here.
    @Test func otherPagesAreNotHandled() {
        let panels = BrowserPopupPanels()
        #expect(!panels.handle(makePage(), .close))
    }
}
