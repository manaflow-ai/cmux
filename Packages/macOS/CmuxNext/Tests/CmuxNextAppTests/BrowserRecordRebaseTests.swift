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
