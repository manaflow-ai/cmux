import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextBridge

/// Daemon browser tabs carry their page address into the strip item
/// (`TabItem.location`, the strip's location field); terminals, the New Tab
/// page and internal pages carry none. `PaneController.snapshot` builds
/// every daemon tab's item here.
@MainActor
struct TabItemLocationTests {
    /// The fixture tree with its second tab (surface 13) turned into a
    /// browser tab at `url`.
    private func browserTab(url: String?) throws -> (browser: TabModel, terminal: TabModel) {
        let fixture = try #require(Bundle.module.url(forResource: "list-workspaces", withExtension: "json", subdirectory: "Fixtures"))
        var tree = try JSONDecoder().decode(BridgeFixture.Envelope.self, from: Data(contentsOf: fixture)).data
        tree.workspaces[0].screens[0].panes[0].tabs[1].kind = .browser
        tree.workspaces[0].screens[0].panes[0].tabs[1].url = url
        let store = DaemonStore()
        store.apply(snapshot: tree)
        let browser = try #require(store.tab(surface: 13))
        let terminal = try #require(store.tab(surface: 3))
        return (browser, terminal)
    }

    private func item(_ tab: TabModel) -> StripTabItem {
        TabItemMapping.shared.item(tab, fallbackTitle: "Untitled")
    }

    @Test func aBrowserTabCarriesItsLocation() throws {
        let tabs = try browserTab(url: "https://example.com/docs?q=1")
        let location = try #require(item(tabs.browser).location)
        #expect(location.url.absoluteString == "https://example.com/docs?q=1")
        #expect(location.isSecure)
        #expect(item(tabs.terminal).location == nil, "a terminal tab has none")
    }

    /// A Chromium New Tab page never names itself, so its recorded title
    /// is its address; the strip shows the fallback ("New Tab") instead.
    @Test(arguments: ["chrome://newtab/", "about:blank"])
    func theNewTabPageReadsAsTheFallbackTitle(_ address: String) throws {
        let fixture = try #require(Bundle.module.url(forResource: "list-workspaces", withExtension: "json", subdirectory: "Fixtures"))
        var tree = try JSONDecoder().decode(BridgeFixture.Envelope.self, from: Data(contentsOf: fixture)).data
        tree.workspaces[0].screens[0].panes[0].tabs[1].kind = .browser
        tree.workspaces[0].screens[0].panes[0].tabs[1].url = address
        tree.workspaces[0].screens[0].panes[0].tabs[1].title = address
        tree.workspaces[0].screens[0].panes[0].tabs[1].name = nil
        let store = DaemonStore()
        store.apply(snapshot: tree)
        let tab = try #require(store.tab(surface: 13))
        #expect(item(tab).title == "Untitled")
    }

    @Test func anHttpPageIsNotSecure() throws {
        let tabs = try browserTab(url: "http://localhost:3000/")
        #expect(item(tabs.browser).location?.isSecure == false)
    }

    @Test func theNewTabPageAndInternalPagesHaveNone() throws {
        for url in ["about:blank", "chrome://newtab/", "cmux://settings", nil] as [String?] {
            let tab = try browserTab(url: url).browser
            #expect(item(tab).location == nil, "\(url ?? "nil")")
        }
    }
}
