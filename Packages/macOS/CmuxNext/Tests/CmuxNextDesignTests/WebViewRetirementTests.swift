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
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WebViewRetirementTests {
    /// Records the pages it closes; ``waitForCloses(_:)`` waits until it has closed that many.
    @MainActor private final class Closer {
        private(set) var closed: [ObjectIdentifier] = []
        private var waiter: CheckedContinuation<Void, Never>?

        private var wanted = 0

        func close(_ webView: WKWebView) {
            closed.append(ObjectIdentifier(webView))
            guard closed.count >= wanted, let waiter else { return }
            self.waiter = nil
            waiter.resume()
        }

        func waitForCloses(_ count: Int) async {
            guard closed.count < count else { return }
            wanted = count
            await withCheckedContinuation { waiter = $0 }
        }
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
        #expect(closer.closed.isEmpty)
        #expect(!retirement.isFinished)
        clock.advance(by: .seconds(1))
        await closer.waitForCloses(1)
        #expect(retirement.isFinished)
        #expect(closer.closed == [ObjectIdentifier(webView)])
    }

    /// Nobody holds the retirement: its deadline keeps it, and the view, until the page closed.
    @Test func anUnheldRetirementKeepsTheViewUntilItsPageCloses() async throws {
        let clock = ManualClock()
        let closer = Closer()
        weak var released: WKWebView?
        let window: NSWindow = autoreleasepool {
            let (webView, window) = Self.webViewInWindow()
            released = webView
            WebViewRetirement(webView, quietPeriod: .seconds(3), clock: clock, closePage: closer.close)
            return window
        }
        defer { window.close() }
        #expect(released != nil, "the retirement holds the view through the quiet period")

        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        await closer.waitForCloses(1)
        #expect(closer.closed.count == 1)
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

}
