import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// TOP-SECTION-ITEMS-ARE-PAGES Q3: History and Bookmarks placed in the top
/// section open as top pages (in the bottom section they stay tabs). A row
/// or link opened from such a page opens in the window's workspace. The
/// Bookmarks page shows the bookmarks of the workspace's browser profile.
@MainActor
struct BrowserAppTopPageTests {
    @Test func historyAndBookmarksOnTopAreTheirPages() {
        #expect(TopPageRoute(.builtIn(.history), in: .top) == .page(.history))
        #expect(TopPageRoute(.builtIn(.bookmarks), in: .top) == .page(.bookmarks))
        #expect(TopPageRoute(.builtIn(.history), in: .bottom) == nil)
    }

    @Test func historyAndBookmarksHavePageProviders() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(services.pages.provider(.history) != nil)
        #expect(services.pages.provider(.bookmarks) != nil)
    }

    @Test func theHistoryPageShowsAndLeavingReturnsToTheWorkspaceAtOnce() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        let shown = try #require(window.content)
        #expect(TopPages.show(.page(.history), services: services, in: state) != nil)
        #expect(window.shownTopPage == .page(.history))
        #expect(TopPages.leave(services), "a page was left")
        #expect(state.page == nil)
        #expect(window.content === shown, "the workspace is back in the same turn, for the row to open in")
        #expect(!TopPages.leave(services), "nothing to leave")
        window.teardown()
        withExtendedLifetime(services) {}
    }

    /// The Bookmarks page uses the profile of the workspace's browser tab;
    /// with no browser tab, the default profile.
    @Test func bookmarksUseTheWorkspacesBrowserTab() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try Self.tree(browser: true))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let browser = try #require(workspace.screens.first?.panes.first?.tabs.first { $0.kind == .browser })
        let state = WindowState(workspaceID: workspace.id)
        let window = WindowController(state: state, services: services, frame: nil)
        services.windows.didActivate(window)
        #expect(TopPages.bookmarkTab(of: window, services: services) == browser.id)
        services.daemon.store.apply(snapshot: try Self.tree(browser: false))
        #expect(TopPages.bookmarkTab(of: window, services: services) == nil)
        #expect(TopPages.bookmarkProfile(of: window, services: services) == "default")
        window.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// One workspace, one pane: a terminal tab, and a WebKit tab when `browser`.
    static func tree(browser: Bool) throws -> DaemonTree {
        var tabs = [#"{"kind":"terminal","name":"t","surface":5,"dead":false}"#]
        if browser {
            tabs.append(#"{"kind":"browser","name":"","surface":6,"dead":false,"browser_renderer":"frontend","browser_engine":"webkit","url":"about:blank"}"#)
        }
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[\(tabs.joined(separator: ","))]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }
}
