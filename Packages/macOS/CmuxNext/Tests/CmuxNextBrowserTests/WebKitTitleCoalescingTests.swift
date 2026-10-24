import AppKit
@testable import CmuxNextBrowser
import Testing

/// A WebKit page whose title ticks (a timer, "(3) Inbox") reaches the tab's
/// state at most 4 times a second, as a Chromium page does
/// (`TitleCoalescer`). WebKit applied every change, and each one re-rendered
/// the toolbar and rows and wrote a history title (QA spree 2026-10-21).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitTitleCoalescingTests {
    @Test func aTickingTitleIsCoalesced() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        page.webView.frame = window.contentLayoutRect
        window.contentView = page.webView
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
            page.close()
        }
        final class Titles { var seen: [String?] = [] }
        let titles = Titles()
        let observer = page.observeNavigationEvents { event in
            if case .titleChanged(let title) = event { titles.seen.append(title) }
        }
        defer { page.removeNavigationObserver(observer) }
        page.webView.loadHTMLString("""
        <title>t0</title><script>let n = 0; setInterval(() => { document.title = "t" + (++n) }, 10)</script>
        """, baseURL: nil)
        // A measurement window, not a wait for a state: the page ticks about 100 times a second.
        try await Task.sleep(for: .milliseconds(1500))
        let ticks = titles.seen.compactMap { $0 }.filter { $0 != "t0" }.count
        try #require(ticks > 0, "the page never changed its title")
        #expect(ticks <= 10, "\(ticks) title changes reached the state in 1.5 s")
    }
}
