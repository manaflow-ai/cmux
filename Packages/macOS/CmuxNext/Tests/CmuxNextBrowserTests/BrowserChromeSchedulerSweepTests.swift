import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// The browser chrome's sweep onto the main-thread scheduler (p06-scheduler-321,
/// plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9): one case per migrated owner class.
/// - A hidden tab's chrome, address bar and toolbar do no repaint while hidden and repaint once on
///   show (R-appear, R-hide on the tab's node, Chromium's per-WebContents visibility).
/// - A chrome with no tab node (a debug window) repaints at once, as before.
/// - A query's rows reach the reducer as posted userBlocking tasks (R-hop), and a cancelled query's
///   posted rows do nothing.
@MainActor @Suite(.serialized) struct BrowserChromeSchedulerSweepTests {
    private static func chrome(node: VisibilityNode?) -> BrowserChromeView {
        let engine = MockBrowserEngine()
        let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: tab, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: node)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        return chrome
    }

    private static let sentinel = CGColor(red: 1, green: 0, blue: 1, alpha: 1)

    @Test func aHiddenTabRepaintsItsChromeOnceOnShow() {
        let node = VisibilityNode(root: "tab", own: .hidden)
        let chrome = Self.chrome(node: node)
        chrome.layer?.backgroundColor = Self.sentinel
        let before = node.deferredCount

        chrome.viewDidChangeEffectiveAppearance()
        chrome.viewDidChangeEffectiveAppearance()

        #expect(node.deferredCount == before + 1, "two appearance changes of a hidden tab keep one repaint")
        #expect(chrome.layer?.backgroundColor == Self.sentinel, "a hidden tab's chrome repainted")
        node.set(.visible)
        #expect(node.deferredCount == 0)
        #expect(chrome.layer?.backgroundColor != Self.sentinel, "the shown tab did not repaint")
    }

    @Test func aChromeWithNoTabNodeRepaintsAtOnce() {
        let chrome = Self.chrome(node: nil)
        chrome.layer?.backgroundColor = Self.sentinel

        chrome.viewDidChangeEffectiveAppearance()

        #expect(chrome.layer?.backgroundColor != Self.sentinel)
        #expect(chrome.visibilityNode.isVisible)
    }

    @Test func theBarFieldPillAndToolbarWaitOnTheTabNode() {
        let node = VisibilityNode(root: "tab", own: .hidden)
        let chrome = Self.chrome(node: node)
        #expect(chrome.addressBar.visibilityNode === node)
        #expect(chrome.addressBar.field.visibilityNode === node)
        #expect(chrome.addressBar.pill.visibilityNode === node)
        #expect(chrome.toolbarButtons.visibilityNode === node)
        let before = node.deferredCount

        chrome.addressBar.viewDidChangeEffectiveAppearance()
        chrome.addressBar.field.viewDidChangeEffectiveAppearance()
        chrome.addressBar.pill.viewDidChangeEffectiveAppearance()
        chrome.toolbarButtons.viewDidUnhide()
        chrome.viewDidUnhide()

        #expect(node.deferredCount == before + 5, "each view keeps one repaint while its tab is hidden")
        node.set(.visible)
        #expect(node.deferredCount == 0, "every repaint ran on show")
    }

    @Test func aQuerysRowsReachTheReducerAsPostedTasks() async {
        let bar = AddressBarView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView?.addSubview(bar)
        let row = BrowserSuggestion(kind: .search, title: "cmux docs", detail: "", url: URL(string: "https://cmux.dev/")!, score: 1)
        let (rows, delivery) = AsyncStream<OmniboxDelivery>.makeStream()
        bar.controller.suggest = { _ in rows }

        bar.controller.send(.focusGained(.keyboard))
        bar.controller.send(.fieldChanged(.init(text: "cm", selection: NSRange(location: 2, length: 0)), .insert))
        delivery.yield(.local([row]))
        delivery.finish()
        await Self.settle { bar.controller.state.popup.rows.contains(row) }

        #expect(bar.controller.state.popup.rows.contains(row), "the delivered row never reached the reducer")
    }

    @Test func aCancelledQuerysPostedRowsDoNothing() async {
        let bar = AddressBarView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let row = BrowserSuggestion(kind: .search, title: "stale", detail: "", url: URL(string: "https://stale.example/")!, score: 1)
        let (rows, delivery) = AsyncStream<OmniboxDelivery>.makeStream()
        bar.controller.suggest = { _ in rows }
        bar.controller.send(.focusGained(.keyboard))
        bar.controller.send(.fieldChanged(.init(text: "st", selection: NSRange(location: 2, length: 0)), .insert))

        delivery.yield(.local([row]))
        delivery.finish()
        bar.controller.send(.focusLost)
        await Self.settle { false }

        #expect(!bar.controller.state.popup.rows.contains(row), "rows of a query that ended reached the reducer")
    }

    /// Posted tasks run on the main run loop, which no display link drives here: spin it until `done`
    /// (bounded).
    private static func settle(until done: () -> Bool) async {
        for _ in 0..<40 where !done() {
            await Task.yield()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }
}
