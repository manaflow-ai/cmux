import AppKit
import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Testing
import WebKit

/// Nightly crash 2026-10-25 (Cmd-W held over many tabs): macOS 26.6's WebKit frees a page's scroll
/// event dispatcher still registered with the display link when the page closes while it scrolls,
/// and the display-link thread crashes on the next refresh (bugs.webkit.org 315775).
/// `WebViewRetirement` takes a closed page's web view out of its window at once and closes its page
/// only after the scrolling stopped, on its own turn.
@MainActor
@Suite(.serialized)
struct WebViewRetirementTests {
    /// Records the pages it closes.
    @MainActor private final class Closer {
        private(set) var closed: [ObjectIdentifier] = []
        func close(_ webView: WKWebView) { closed.append(ObjectIdentifier(webView)) }
    }

    private static func webViewInWindow() -> (WKWebView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: WKWebViewConfiguration())
        window.contentView?.addSubview(webView)
        return (webView, window)
    }

    @Test func aRetiredViewLeavesItsWindowAtOnceAndItsPageClosesAfterTheQuietPeriod() async throws {
        let clock = ManualClock()
        let closer = Closer()
        let (webView, window) = Self.webViewInWindow()
        defer { window.close() }

        let retirement = WebViewRetirement(webView, quietPeriod: .seconds(3), clock: clock, closePage: closer.close)
        #expect(webView.superview == nil)
        #expect(webView.window == nil)
        #expect(closer.closed.isEmpty, "the page stays open while its scrolling may still run")

        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
        await Self.yield()
        #expect(closer.closed.isEmpty)
        clock.advance(by: .seconds(1))
        try await Self.until { retirement.isFinished }
        #expect(closer.closed == [ObjectIdentifier(webView)])
    }

    /// Nobody holds the retirement: its deadline keeps it, and the view, until the page closed.
    @Test func anUnheldRetirementKeepsTheViewUntilItsPageCloses() async throws {
        let clock = ManualClock()
        let closer = Closer()
        weak var released: WKWebView?
        weak var retirement: WebViewRetirement?
        let window: NSWindow = autoreleasepool {
            let (webView, window) = Self.webViewInWindow()
            released = webView
            retirement = WebViewRetirement(webView, quietPeriod: .seconds(3), clock: clock, closePage: closer.close)
            return window
        }
        defer { window.close() }
        #expect(released != nil, "the retirement holds the view through the quiet period")
        #expect(retirement != nil)

        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        try await Self.until { closer.closed.count == 1 }
        try await Self.until { retirement == nil }
    }

    @Test func finishingEarlyClosesThePageOnce() {
        let closer = Closer()
        let (webView, window) = Self.webViewInWindow()
        defer { window.close() }

        let retirement = WebViewRetirement(webView, quietPeriod: .seconds(3), clock: ManualClock(), closePage: closer.close)
        retirement.finish()
        retirement.finish()
        #expect(closer.closed == [ObjectIdentifier(webView)])
        #expect(retirement.isFinished)
    }

    /// The real close: WebKit's page of the view is closed (`_isClosed`), and the retirement no
    /// longer holds the view.
    @Test func theDefaultCloseClosesTheWebKitPageAndLetsTheViewGo() throws {
        weak var released: WKWebView?
        autoreleasepool {
            let (webView, window) = Self.webViewInWindow()
            defer { window.close() }
            released = webView
            #expect(WebViewRetirement.isPageClosed(webView) == false)
            let retirement = WebViewRetirement(webView, clock: ManualClock())
            retirement.finish()
            #expect(WebViewRetirement.isPageClosed(webView) == true)
        }
        #expect(released == nil)
    }

    private static func yield() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Yields the main actor until `condition` holds (the deadline's action runs on it).
    private static func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        try #require(condition())
    }
}
