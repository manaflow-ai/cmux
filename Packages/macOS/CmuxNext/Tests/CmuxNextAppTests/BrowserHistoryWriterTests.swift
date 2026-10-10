@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// Session history across relaunch (plans/cmux-next/browser.md): a page's
/// back/forward entries and scroll positions go to the daemon, and a tab
/// that reopens at the saved page gets them back.
@MainActor
struct BrowserHistoryWriterTests {
    private static func page(_ name: String) -> BrowserNavigationEntry {
        BrowserNavigationEntry(url: URL(string: "https://\(name).test/"), title: name.uppercased())
    }

    private static func entry(_ name: String, scrollY: Double? = nil) -> FrontendBrowserHistory.Entry {
        FrontendBrowserHistory.Entry(url: "https://\(name).test/", title: name.uppercased(), scrollY: scrollY)
    }

    private static func tabRecord(url: String) -> String {
        #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"cef","url":"\#(url)"}"#
    }

    @Test func aSettledNavigationSendsTheEntries() async {
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let gate = SleepGate()
        var sent: [FrontendBrowserHistory] = []
        let writer = BrowserHistoryWriter(page: page, recorded: nil, delay: .milliseconds(500), sleep: { _ in try await gate.wait() }) {
            sent.append($0)
            return true
        }
        page.navigation = BrowserNavigationList(entries: [Self.page("a"), Self.page("b")], current: 1)
        page.load(URL(string: "https://b.test/")!)
        page.simulate(.titleChanged("B"))
        await BrowserTabTests.settle { gate.waiters > 0 }
        #expect(sent.isEmpty, "nothing is sent before the delay")
        gate.releaseAll()
        await BrowserTabTests.settle { !sent.isEmpty }
        #expect(sent == [FrontendBrowserHistory(entries: [Self.entry("a"), Self.entry("b")], index: 1)])
        writer.cancel()
    }

    /// Scrolling fires no page event: quit measures the shown page, and an
    /// unchanged history is not sent again.
    @Test func quitSendsTheShownPagesScrollPosition() async {
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        page.load(URL(string: "https://a.test/")!)
        page.simulate(.titleChanged("A"))
        page.scrollPosition = { 420 }
        var sent: [FrontendBrowserHistory] = []
        let writer = BrowserHistoryWriter(page: page, recorded: nil, delay: .milliseconds(500), sleep: { _ in try await Task.sleep(for: .seconds(60)) }) {
            sent.append($0)
            return true
        }
        await writer.flushNow()
        #expect(sent == [FrontendBrowserHistory(entries: [Self.entry("a", scrollY: 420)], index: 0)])
        await writer.flushNow()
        #expect(sent.count == 1)
        writer.cancel()
    }

    /// A page that does not answer in time does not hold up quit; its
    /// entries go without a fresh scroll position.
    @Test func quitDoesNotWaitForAPageThatDoesNotAnswer() async {
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        page.load(URL(string: "https://a.test/")!)
        page.simulate(.titleChanged("A"))
        let budget = SleepGate(), stuck = SleepGate()
        page.scrollPosition = {
            try? await stuck.wait()
            return 1
        }
        var sent: [FrontendBrowserHistory] = []
        let writer = BrowserHistoryWriter(page: page, recorded: nil, delay: .milliseconds(500), sleep: { _ in try await budget.wait() }) {
            sent.append($0)
            return true
        }
        await BrowserTabTests.settle { budget.waiters > 0 }
        let waiting = budget.waiters
        let flush = Task { await writer.flushNow() }
        await BrowserTabTests.settle { budget.waiters > waiting && stuck.waiters > 0 }
        budget.releaseAll()
        await flush.value
        #expect(sent == [FrontendBrowserHistory(entries: [Self.entry("a")], index: 0)])
        stuck.releaseAll()
        writer.cancel()
    }

    /// A tab reopening at the page its history was saved on gets the saved
    /// entries; one reopening elsewhere (the record moved on) does not.
    @Test(arguments: [("https://b.test/", true), ("https://other.test/", false)])
    func aReopenedTabGetsItsSavedEntries(recordURL: String, restores: Bool) async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: Self.tabRecord(url: recordURL)))
        let browserTabs = try #require(services.cache.browserTabs)
        browserTabs.update = { _, _ in true }
        let saved = FrontendBrowserHistory(entries: [Self.entry("a", scrollY: 10), Self.entry("b", scrollY: 300), Self.entry("c")], index: 1)
        var fetched: [SurfaceID] = []
        browserTabs.fetchHistory = { surface in
            fetched.append(surface)
            return saved
        }
        browserTabs.storeHistory = { _, _ in true }
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        browserTabs.track(page, for: model)
        await BrowserTabTests.settle { !fetched.isEmpty && (!restores || !page.restoredSessions.isEmpty) }
        #expect(fetched == [SurfaceID(rawValue: 9)])
        let expected = BrowserSavedSession(entries: [
            BrowserSavedEntry(url: URL(string: "https://a.test/")!, title: "A", scrollY: 10),
            BrowserSavedEntry(url: URL(string: "https://b.test/")!, title: "B", scrollY: 300),
            BrowserSavedEntry(url: URL(string: "https://c.test/")!, title: "C"),
        ], current: 1)
        #expect(page.restoredSessions == (restores ? [expected] : []))
        browserTabs.untrack(model.id)
        withExtendedLifetime(services) {}
    }

    @Test func anIncognitoTabKeepsNoHistory() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: Self.tabRecord(url: "about:blank")))
        let browserTabs = try #require(services.cache.browserTabs)
        var touched = false
        browserTabs.fetchHistory = { _ in
            touched = true
            return nil
        }
        browserTabs.storeHistory = { _, _ in
            touched = true
            return true
        }
        browserTabs.sleep = { _ in }
        browserTabs.isIncognitoTab = { _ in true }
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        browserTabs.track(page, for: model)
        page.load(URL(string: IncognitoRecordTests.secret)!)
        await browserTabs.flushRecords()
        for _ in 0..<500 { await Task.yield() }
        #expect(!touched)
        withExtendedLifetime(services) {}
    }

    @Test func aStoredHistoryWithABadEntryIsNotRestored() {
        let bad = FrontendBrowserHistory(entries: [Self.entry("a"), .init(url: "")], index: 0)
        #expect(BrowserHistoryWriter.session(bad) == nil)
        let outOfRange = FrontendBrowserHistory(entries: [Self.entry("a")], index: 3)
        #expect(BrowserHistoryWriter.session(outOfRange) == nil)
    }
}
