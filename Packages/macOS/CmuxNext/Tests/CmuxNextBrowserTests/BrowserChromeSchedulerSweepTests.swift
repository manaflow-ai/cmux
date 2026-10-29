import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// The browser chrome's sweep onto the main-thread scheduler
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9): one case per migrated owner class.
/// - A hidden tab's chrome, address bar and toolbar do no repaint while hidden and repaint once on
///   show (R-appear, R-hide on the tab's node, Chromium's per-WebContents visibility).
/// - A chrome with no tab node (a debug window) repaints at once, as before.
/// - A hidden tab's https fallback still loads, as one userBlocking task (a side effect sent while hidden).
/// - A query's rows reach the reducer as posted userBlocking tasks (R-hop), and a delivery posted
///   before its query ended does nothing.
/// - The Extensions bubble's prepare is one idle task for the renders queued before it, held while its tab
///   is hidden; its refresh is one userBlocking task of the open still shown.
/// The long press of Back and Forward (R-timer) is `ChromeIconButtonLongPressTests`.
@MainActor @Suite(.serialized) struct BrowserChromeSchedulerSweepTests {
    private static func chrome(node: VisibilityNode?, work: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
                               url: URL? = URL(string: "https://example.com/")) -> BrowserChromeView {
        let engine = MockBrowserEngine()
        let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: url))
        let chrome = BrowserChromeView(tab: tab, mainWork: work, node: node)
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

    /// Side effects still sent while hidden: a hidden tab's refused https upgrade loads over http, as one
    /// userBlocking task after the render that saw the failure, never inside it.
    @Test func aHiddenTabsHTTPSFallbackLoadsAsOneUserBlockingTask() throws {
        let rig = BrowserSweepRig()
        let node = VisibilityNode(root: "tab", own: .hidden, uptime: rig.clock.uptime)
        let chrome = Self.chrome(node: node, work: rig.work, url: nil)
        let tab = try #require(chrome.tab as? MockBrowserTab)
        let https = try #require(URL(string: "https://example.com/"))
        let http = try #require(URL(string: "http://example.com/"))
        rig.drain()
        chrome.httpsFallback.expect(https)

        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: https))
        tab.simulate(.failed(id, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, message: "",
                                                  failingURL: https)))
        #expect(!tab.commands.contains(.load(http)), "the fallback loaded inside the failure's turn")
        rig.drain()

        #expect(tab.commands.filter { $0 == .load(http) }.count == 1, "a hidden tab's fallback did not load once")
        #expect(rig.classes(of: "browser.chrome.httpsFallback") == [.userBlocking])
        #expect(!node.isVisible)
    }

    /// A delivery reaches the reducer as one userBlocking task of `browser.omnibar.suggestions`, posted from
    /// the off-main reader: it has not run when it is posted.
    @Test func aQuerysRowsArePostedAsUserBlockingTasks() async throws {
        let rig = BrowserSweepRig()
        let (bar, window) = Self.bar(on: rig.work)
        defer { window.close() }
        let row = BrowserSuggestion(kind: .search, title: "cmux docs", detail: "", url: try #require(URL(string: "https://cmux.dev/")), score: 1)
        let (rows, delivery) = AsyncStream<OmniboxDelivery>.makeStream()
        defer { delivery.finish() }
        bar.controller.suggest = { _ in rows }
        bar.controller.send(.focusGained(.keyboard))
        bar.controller.send(.fieldChanged(.init(text: "cm", selection: NSRange(location: 2, length: 0)), .insert))
        rig.drain()
        let posted = rig.work.postedCount(.userBlocking)

        delivery.yield(.local([row]))
        await rig.spin { rig.work.postedCount(.userBlocking) > posted }
        #expect(rig.work.postedCount(.userBlocking) == posted + 1, "the delivery was not posted as one userBlocking task")
        #expect(!bar.controller.state.popup.rows.contains(row), "the delivery reached the reducer before its task ran")
        rig.drain()

        #expect(bar.controller.state.popup.rows.contains(row), "the delivered row never reached the reducer")
        #expect(rig.classes(of: "browser.omnibar.suggestions") == [.userBlocking])
    }

    /// A delivery posted before its query ended does nothing: the person cleared the text, which cancels the
    /// query with no new generation, so only the controller's epoch tells the delivery is stale.
    @Test func aDeliveryPostedBeforeItsQueryEndedDoesNothing() async throws {
        let rig = BrowserSweepRig()
        let (bar, window) = Self.bar(on: rig.work)
        defer { window.close() }
        let row = BrowserSuggestion(kind: .search, title: "stale", detail: "", url: try #require(URL(string: "https://stale.example/")), score: 1)
        let (rows, delivery) = AsyncStream<OmniboxDelivery>.makeStream()
        defer { delivery.finish() }
        bar.controller.suggest = { _ in rows }
        bar.controller.send(.focusGained(.keyboard))
        bar.controller.send(.fieldChanged(.init(text: "st", selection: NSRange(location: 2, length: 0)), .insert))
        rig.drain()
        let posted = rig.work.postedCount(.userBlocking)
        let generation = bar.controller.state.generation

        delivery.yield(.local([row]))
        await rig.spin { rig.work.postedCount(.userBlocking) > posted }
        #expect(rig.work.postedCount(.userBlocking) == posted + 1, "the delivery was not posted before the clear")
        bar.controller.send(.fieldChanged(.init(text: "", selection: NSRange(location: 0, length: 0)), .delete))
        #expect(bar.controller.state.generation == generation, "the clear started a generation: the reducer alone drops the rows")
        rig.drain()

        #expect(!bar.controller.state.popup.rows.contains(row), "rows of a query that ended reached the reducer")
    }

    /// The Extensions bubble's prepare: one idle task for the renders queued before it, held while its tab is
    /// hidden past 10 s (past its 500 ms bound too) until the tab shows, and queued again by a render after it ran.
    @Test func theBubblesPrepareIsOneIdleTaskHeldWhileTheTabIsHidden() {
        let rig = BrowserSweepRig()
        let window = VisibilityNode(root: "window", own: .visible, uptime: rig.clock.uptime)
        let node = VisibilityNode("tab", own: .hidden, parent: window)
        rig.timer.run(ms: 10_000)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: nil))
        tab.showsExtensionToolbar = true
        let toolbar = ExtensionActionToolbar(slot: NSStackView(), mainWork: rig.work, node: node)
        let owner = "browser.extensions.menu.prepare"

        toolbar.bind(tab)
        toolbar.bind(tab)
        #expect(rig.work.idle.count == 1, "two renders queued two prepares")
        rig.timer.run(ms: 1_000)
        rig.drain()
        #expect(rig.runs(of: owner) == 0, "a hidden tab's prepare ran")

        node.set(.visible)
        rig.drain()
        #expect(rig.runs(of: owner) == 1, "the shown tab did not prepare once")
        #expect(rig.work.idle.count == 0)

        toolbar.bind(tab)
        #expect(rig.work.idle.count == 1, "a render after the prepare ran queued none")
    }

    /// The bubble's refresh is one userBlocking task after the open: a bubble closed before it runs refreshes
    /// nothing, and of an open, a close and a reopen in one turn only the reopen's refreshes.
    @Test(.enabled("a bubble needs a screen to show") { await ExtensionsMenuPerformanceTests.hasDisplay() })
    func theBubblesRefreshIsOneUserBlockingTaskOfTheOpenStillShown() throws {
        let rig = BrowserSweepRig()
        let tab = ExtensionsMenuPerformanceTests.tab(extensions: 2)
        let (window, anchor) = ExtensionsMenuPerformanceTests.window()
        defer { window.close() }
        let handler = ExtensionsMenu.DirectHandler(host: tab) { _ in }
        let controller = ExtensionsMenuController(mainWork: rig.work)
        let before = tab.extensionBackend.snapshots

        controller.show(host: tab, handler: handler, anchor: anchor)
        try #require(controller.isShown, "\(ExtensionsMenuPerformanceTests.environment(window))")
        controller.close()
        rig.drain()
        #expect(tab.extensionBackend.snapshots == before, "a bubble closed before its refresh's turn refreshed")

        controller.show(host: tab, handler: handler, anchor: anchor)
        controller.close()
        controller.show(host: tab, handler: handler, anchor: anchor)
        #expect(tab.extensionBackend.snapshots == before, "the open waited for Chromium")
        rig.drain()
        #expect(tab.extensionBackend.snapshots == before + 1, "the closed open's refresh ran for the reopen")
        #expect(rig.classes(of: "browser.extensions.menu.refresh") == [.userBlocking])
        controller.close()
    }

    /// An address bar in a window, on `work`.
    private static func bar(on work: MainWorkScheduler) -> (AddressBarView, NSWindow) {
        let bar = AddressBarView(mainWork: work)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView?.addSubview(bar)
        return (bar, window)
    }
}
