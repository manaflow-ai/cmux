@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// The browser record writer compared each page against the record it saw
/// when tracking began. When the daemon's record changed afterwards (another
/// client, a restore), a page returning to the old URL looked unchanged and
/// was never written, leaving the daemon on the other URL. The writer now
/// re-bases its copy on the daemon's deltas.
@MainActor
struct BrowserRecordRebaseTests {
    static func tab(url: String) -> String {
        #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"cef","url":"\#(url)"}"#
    }

    @Test func aPageReturningToTheOldURLIsWrittenAfterTheDaemonRecordMoved() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: Self.tab(url: "https://a.test/")))
        let browserTabs = try #require(services.cache.browserTabs)
        var sent: [BrowserRecordUpdate] = []
        browserTabs.update = { _, update in
            sent.append(update)
            return true
        }
        browserTabs.sleep = { _ in }
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        browserTabs.track(page, for: model)

        // Another client moved the daemon's record to b.test.
        store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: Self.tab(url: "https://b.test/")))
        for _ in 0..<200 { await Task.yield() }
        // This page is (still) on a.test: the record must come back to it.
        page.load(URL(string: "https://a.test/")!)
        for _ in 0..<500 where sent.isEmpty { await Task.yield() }
        #expect(sent.last?.url == "https://a.test/")
        withExtendedLifetime(services) {}
    }
}

/// On a daemon with state resources a page's zoom and back/forward lists
/// are saved to its tab record (`tab.update`), and its zoom comes back.
@MainActor
struct BrowserRecordStateTests {
    @Test func zoomIsRestoredAndSavedToTheTabRecord() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.noteHandshake(DaemonIdentity(capabilities: [DaemonCapabilities.shared.stateResources], generation: "g1"))
        let tab = #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"cef","url":"https://a.test/","tab_resource_id":"tab_b"}"#
        store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: tab))
        var state = SessionStateMirror()
        state.tabs[ResourceID(rawValue: "tab_b")] = .init(zoom: 1.5)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .sessionState(.snapshot(state)))])
        let browserTabs = try #require(services.cache.browserTabs)
        var saved: [(ResourceID, BrowserRecordUpdate)] = []
        browserTabs.update = { _, _ in true }
        browserTabs.updateState = { tab, update in
            saved.append((tab, update))
            return true
        }
        browserTabs.sleep = { _ in }
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        browserTabs.track(page, for: model)
        #expect(page.state.zoom == 1.5)

        page.setZoom(2)
        for _ in 0..<500 where saved.isEmpty { await Task.yield() }
        #expect(saved.first?.0 == ResourceID(rawValue: "tab_b"))
        #expect(saved.first?.1.zoom == .set(2))
        withExtendedLifetime(services) {}
    }

    @Test func historyListsAreComparedOnlyWhereTheDaemonKeepsThem() {
        let record = BrowserRecord(url: "https://c.test/", back: ["https://a.test/"])
        var page = BrowserTabState(url: URL(string: "https://c.test/"))
        page.backURLs = ["https://a.test/", "https://b.test/"]
        page.forwardURLs = []
        #expect(record.update(toward: page) == nil)
        let update = record.update(toward: page, state: true)
        #expect(update?.back == ["https://a.test/", "https://b.test/"])
        #expect(update?.forward == nil)
        #expect(update?.hasRecordFields == false)
        // An engine that reports no lists never clears the saved ones.
        page.backURLs = nil
        #expect(record.update(toward: page, state: true) == nil)
    }
}
