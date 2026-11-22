import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing
import WebKit

/// tab-switch-fast: a Markdown or file viewer tab (an `InternalPageView` around a WKWebView) left the
/// window on every switch away and came back on every switch back. A WKWebView that re-enters a
/// window waits synchronously for its web process (170-215 ms, #20516), so switching to a warm
/// Markdown tab was slow. A warm switch must keep the page in the window, hidden, as terminals and
/// browsers already are.
@MainActor @Suite(.serialized, .closesItsWindows) struct InternalPageParkingTests {
    /// Counts the page's window moves (each one is the re-attach the switch must avoid).
    final class WindowMoves: NSView {
        var moves = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moves += 1
        }
    }

    @Test func aWarmPageStaysInTheWindowAcrossSwitches() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("page"), title: "notes.md"),
                                                                     TabItem(id: TabID("other"), title: "Other")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        let probe = WindowMoves()
        let web = WKWebView(frame: .zero)
        probe.addSubview(web)
        let page = InternalPageView(key: "local-page:markdown:1", page: InternalPageID(rawValue: "markdown"), content: probe)
        let other = InternalPageView(key: "local-page:markdown:2", page: InternalPageID(rawValue: "markdown"), content: NSView())
        pane.show(page)
        pane.layoutSubtreeIfNeeded()
        #expect(page.window === window)
        let entered = probe.moves

        for _ in 0..<3 {
            pane.show(other)
            pane.layoutSubtreeIfNeeded()
            // Away: still in the window, hidden, so it neither draws nor takes events.
            #expect(page.window === window)
            #expect(page.isHidden)
            pane.show(page)
            pane.layoutSubtreeIfNeeded()
            #expect(!page.isHidden)
            #expect(page.frame == pane.contentHost.bounds)
        }
        #expect(probe.moves == entered, "the page left and re-entered the window on a warm switch")
        #expect(web.window === window)
    }
}
