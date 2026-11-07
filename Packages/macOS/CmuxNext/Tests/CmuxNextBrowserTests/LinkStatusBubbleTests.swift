import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The link status bubble (user, 2026-11-03: hovering a link in a browser pane right of the Home dock
/// drew Chrome's "file:///…/H1-dark.png" bubble over the Home chat's composer). Chrome's own bubble is
/// a child window of the page window, outside cmux's page clip, so it landed outside the pane. cmux
/// turns Chrome's bubble off and draws the hovered link itself: inside its own page area, at the
/// bottom left, gone when the page says the pointer left the link.
@MainActor @Suite(.serialized, .closesItsWindows) struct LinkStatusBubbleTests {
    static let hovered = "file:///Users/lawrence/fun/cmux-shots/chief-agent-messages/header/H1-dark.png"

    /// A window with a wide view on the left (the Home dock) and the browser pane on the right.
    struct Panes {
        let window: NSWindow
        let chrome: BrowserChromeView
        let page: MockBrowserTab

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: window.contentLayoutRect)
            window.contentView = root
            page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
            chrome = BrowserChromeView(tab: page)
            chrome.frame = NSRect(x: 600, y: 0, width: 600, height: root.bounds.height)
            root.addSubview(chrome)
            window.orderFrontRegardless()
            chrome.layoutSubtreeIfNeeded()
        }

        /// The page area in screen coordinates.
        var pageOnScreen: NSRect {
            window.convertToScreen(chrome.contentContainer.convert(chrome.contentContainer.bounds, to: nil))
        }

        func tearDown() {
            chrome.removeFromSuperview()
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    /// Lets the chrome's observation of the tab run (it re-renders on the next main-actor turn).
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test func chromiumsStatusEventDecodes() {
        let event = CEFShimEvent(kind: 51, browser: 7, request: 0, a: 0, b: 0, s1: Self.hovered, s2: "")
        #expect(event == .statusMessage(browser: 7, text: Self.hovered))
        #expect(event.browserID == 7)
    }

    @Test func theBubbleShowsInsideItsOwnPaneAtTheBottomLeft() async throws {
        let panes = Panes()
        defer { panes.tearDown() }
        panes.page.linkStatus = Self.hovered
        await settle()
        #expect(panes.chrome.linkStatusText == Self.hovered)
        let bubble = try #require(panes.chrome.linkStatusBubble)
        #expect(panes.chrome.linkStatusPlacement == "overlay_host", "above the page window, as Chrome draws it")
        let window = try #require(bubble.window)
        let frame = window.convertToScreen(bubble.convert(bubble.bounds, to: nil))
        let page = panes.pageOnScreen
        #expect(page.contains(frame), "the bubble \(frame) stays inside its own page \(page), never over another pane")
        #expect(frame.minX - page.minX <= BrowserMetrics.overlayInset + 1, "left edge of the page")
        #expect(frame.minY - page.minY <= BrowserMetrics.overlayInset + 1, "bottom edge of the page")
        #expect(frame.width <= page.width / 2 + 1, "a long URL is cut, not stretched across the page")
    }

    @Test func theBubbleGoesAwayWhenThePointerLeavesTheLink() async {
        let panes = Panes()
        defer { panes.tearDown() }
        panes.page.linkStatus = Self.hovered
        await settle()
        panes.page.linkStatus = nil
        await settle()
        #expect(panes.chrome.linkStatusText == nil)
        #expect(panes.chrome.linkStatusPlacement == nil)
    }

    @Test func aHiddenPaneShowsNoBubble() async {
        let panes = Panes()
        defer { panes.tearDown() }
        panes.page.linkStatus = Self.hovered
        await settle()
        panes.chrome.isHidden = true
        panes.chrome.layoutSubtreeIfNeeded()
        panes.chrome.syncPageOverlays()
        #expect(panes.chrome.linkStatusPlacement != "overlay_host")
    }
}
