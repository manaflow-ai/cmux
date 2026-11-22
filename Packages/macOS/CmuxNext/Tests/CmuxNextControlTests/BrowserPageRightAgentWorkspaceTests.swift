@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// `browser.page.right` when Home has no column right of the chat: the agent's
/// tab opens in the agents' own workspace (``BrowserAgentWorkspace``), which
/// no window shows, instead of answering `not_found` and leaving the agent to
/// split the person's Home (Leo, 2026-11-22: "product bug/gap, again"). No
/// action runs (no `openBrowser`, no split), the focus stays, and each agent
/// keeps its own tab there.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageRightAgentWorkspaceTests {
    /// Opens a tab as the app's host does: in workspace `inWorkspace`, else in a new workspace
    /// with the fixed key, published to the router's topology.
    final class FakeHost: BrowserAgentWorkspaceHost {
        struct Open: Equatable { var url: String?, workspace: String?, name: String }
        let opens = Mutex<[Open]>([])
        let router = Mutex<ControlRouter?>(nil)

        @MainActor func openAgentTab(url: String?, inWorkspace workspace: String?, named name: String) async throws
            -> (tab: String, workspace: String) {
            let number = opens.withLock { list -> Int in
                list.append(Open(url: url, workspace: workspace, name: name))
                return list.count
            }
            let tab = "tab_agent\(number)"
            var info = ControlTabInfo(id: tab, surface: "8\(number)", kind: "browser", title: "Agent", url: url)
            info.browserProfileID = BrowserPageService.agentBrowserProfileID
            router.withLock { $0 }?.snapshots.publish { snapshot in
                if let w = snapshot.topology.workspaces.firstIndex(where: { $0.id == BrowserPageService.agentWorkspaceKey }) {
                    snapshot.topology.workspaces[w].screens[0].panes[0].tabs.append(info)
                    snapshot.topology.workspaces[w].screens[0].panes[0].selectedTabID = tab
                } else {
                    let pane = ControlPaneInfo(id: "pane_agents", handle: "70", selectedTabID: tab, tabs: [info])
                    var made = ControlWorkspaceInfo(id: BrowserPageService.agentWorkspaceKey, handle: "71", name: name,
                                                    screens: [ControlScreenInfo(id: "screen_agents", handle: "72", panes: [pane])])
                    made.resourceID = "ws_agents"
                    snapshot.topology.workspaces.append(made)
                }
            }
            return (tab, BrowserPageService.agentWorkspaceKey)
        }

        var count: Int { opens.withLock { $0.count } }
        var last: Open? { opens.withLock { $0.last } }
    }

    func install() -> (ControlRouter, BrowserPageRightTests.OpeningExecutor, FakeHost) {
        let executor = BrowserPageRightTests.OpeningExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        executor.router.withLock { $0 = router }
        let host = FakeHost()
        host.router.withLock { $0 = router }
        BrowserPageService(engine: BrowserPageRightTests.NoEngine(), agentWorkspaces: host).install(on: router)
        router.snapshots.publish { $0 = BrowserPageRightTests.homeSnapshot(rightColumn: false) }
        return (router, executor, host)
    }

    func right(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: "browser.page.right", params: params))
    }

    @Test func aNavigationOpensTheAgentsTabInItsOwnWorkspaceWithoutAColumn() async throws {
        let (router, executor, host) = install()
        let focusBefore = router.snapshots.current.topology.focus
        let result = try await right(router, ["agent": "Chief", "verb": "browser.page.navigate", "url": "https://github.com/settings/apps/new"]).get()
        #expect(result["tab"] == "tab_agent1")
        #expect(result["surface"] == "agent_workspace")
        #expect(result["workspace"] == "ws_agents")
        #expect(result["pane"] == "pane_agents")
        #expect(result["created"] == true)
        #expect(result["navigated"] == true)
        #expect(host.last == FakeHost.Open(url: "https://github.com/settings/apps/new", workspace: nil, name: BrowserAgentWorkspace.name))
        // Nothing ran on the person's window: no openBrowser, no split, and the focus is where it was.
        #expect(executor.count == 0)
        #expect(router.snapshots.current.topology.focus == focusBefore)
        let home = router.snapshots.current.topology.workspaces.first { $0.kind == "home" }
        #expect(home?.panes.map(\.id) == [BrowserPageRightTests.dockPane])
    }

    @Test func theAgentsNextCallsUseItsTab() async throws {
        let (router, _, host) = install()
        _ = try await right(router, ["agent": "Chief", "verb": "browser.page.navigate", "url": "https://cmux.com/"]).get()
        // A read, a click and another navigation all find the tab it opened: no second tab.
        for params: [String: JSONValue] in [["agent": "Chief", "verb": "browser.page.screenshot"],
                                             ["agent": "Chief", "verb": "browser.page.click"],
                                             ["agent": "Chief", "verb": "browser.page.navigate", "url": "https://example.com/"]] {
            let result = try await right(router, params).get()
            #expect(result["tab"] == "tab_agent1")
            #expect(result["created"] == false)
        }
        #expect(host.count == 1)
    }

    @Test func anotherAgentGetsItsOwnTabInTheSameWorkspace() async throws {
        let (router, _, host) = install()
        _ = try await right(router, ["agent": "Chief", "url": "https://cmux.com/"]).get()
        let other = try await right(router, ["agent": "Cloud Chief", "verb": "browser.page.click"]).get()
        #expect(other["tab"] == "tab_agent2")
        #expect(host.last?.workspace == BrowserPageService.agentWorkspaceKey)
        #expect(host.last?.url == nil)
        // The first agent's tab stays its own.
        #expect(try await right(router, ["agent": "Chief", "verb": "browser.page.click"]).get()["tab"] == "tab_agent1")
    }

    @Test func aRenamedAgentWorkspaceIsStillFoundByItsKey() async throws {
        let (router, _, host) = install()
        _ = try await right(router, ["agent": "Chief", "url": "https://cmux.com/"]).get()
        router.snapshots.publish { snapshot in
            if let w = snapshot.topology.workspaces.firstIndex(where: { $0.id == BrowserPageService.agentWorkspaceKey }) {
                snapshot.topology.workspaces[w].name = "Renamed"
            }
        }
        _ = try await right(router, ["agent": "Cloud Chief", "url": "https://example.com/"]).get()
        #expect(host.last?.workspace == BrowserPageService.agentWorkspaceKey)
    }

    @Test func releaseFreesTheAgentWorkspaceTab() async throws {
        let (router, _, _) = install()
        _ = try await right(router, ["agent": "Chief", "url": "https://cmux.com/"]).get()
        let released = try await right(router, ["agent": "Chief", "release": true]).get()
        #expect(released["released"] == ["tab_agent1"])
    }
}
