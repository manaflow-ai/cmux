@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// A browser tab moved to another pane (`cmux browser open` places a new
/// tab, then moves it into a split) keeps writing its title and favicon back
/// to its daemon record. The store makes a new `TabModel` for the tab in the
/// destination pane, so the writer must not depend on the original object.
@MainActor
struct BrowserRecordMoveTests {
    static func tree(pane: Int, tab: String) throws -> DaemonTree {
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"pane":\(pane),"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":\(pane),"name":null,
        "tabs":[\(tab)]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    static let tab = #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"cef","url":"https://example.com"}"#

    @Test func titleReachesTheRecordAfterTheTabMovesToANewPane() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try Self.tree(pane: 3, tab: Self.tab))
        let browserTabs = try #require(services.cache.browserTabs)
        var sent: [(SurfaceID, BrowserRecordUpdate)] = []
        browserTabs.update = { surface, update in
            sent.append((surface, update))
            return true
        }
        browserTabs.sleep = { _ in }
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        do {
            let original = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
            browserTabs.track(page, for: original)
        }
        // The split: the same tab (same surface) now lives in pane 5.
        store.apply(snapshot: try Self.tree(pane: 5, tab: Self.tab))
        #expect(store.workspaces.first?.screens.first?.panes.first?.handle == PaneID(rawValue: 5))

        page.load(URL(string: "https://example.com/")!)
        page.simulate(.titleChanged("Example Domain"))
        for _ in 0..<500 where sent.isEmpty { await Task.yield() }
        #expect(sent.first?.0 == SurfaceID(rawValue: 9))
        #expect(sent.first?.1.title == "Example Domain")
        withExtendedLifetime(services) {}
    }
}
