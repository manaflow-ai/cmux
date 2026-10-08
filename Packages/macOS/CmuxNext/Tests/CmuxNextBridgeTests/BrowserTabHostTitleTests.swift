import CmuxNextDaemon
import CmuxNextTabs
import Testing
@testable import CmuxNextBridge

/// A browser tab whose page was never shown keeps the record the daemon
/// wrote at creation, titled with the full address. The strip names it by
/// the address's host until the page reports its own title (nxdog26).
@MainActor
struct BrowserTabHostTitleTests {
    private func item(title: String, url: String?, name: String? = nil) throws -> StripTabItem {
        let tab = TabSnapshot(surface: 5, kind: .browser, name: name, title: title, url: url)
        let pane = PaneSnapshot(id: 3, tabs: [tab])
        let workspace = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "6f0b8d1e-2c4a-4f7e-9b1d-3a5c7e9f1b2d"), name: "W",
                                          screens: [ScreenSnapshot(id: 4, layout: .leaf(3), panes: [pane])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        return TabItemMapping.shared.item(model, fallbackTitle: "New Tab")
    }

    @Test func aTabTitledWithItsOwnAddressShowsTheHost() throws {
        let unshown = try item(title: "https://example.com/docs?q=1", url: "https://example.com/docs?q=1")
        #expect(unshown.title == "example.com")
        #expect(unshown.subtitle == "https://example.com/docs?q=1")
        #expect(try item(title: "http://127.0.0.1:18931/probe.html", url: "http://127.0.0.1:18931/probe.html").title == "127.0.0.1")
    }

    @Test func aPageTitleAUserNameOrAHostlessAddressIsKept() throws {
        #expect(try item(title: "Example Domain", url: "https://example.com/").title == "Example Domain")
        #expect(try item(title: "https://example.com/", url: "https://example.com/", name: "Docs").title == "Docs")
        #expect(try item(title: "file:///tmp/a.html", url: "file:///tmp/a.html").title == "file:///tmp/a.html")
        #expect(try item(title: "about:blank", url: "about:blank").title == "New Tab")
    }
}
