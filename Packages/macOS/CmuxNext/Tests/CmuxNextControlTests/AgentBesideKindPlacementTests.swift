@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// An agent's browser beside its chat when a column is already right of it (Leo 2026-10-31: "imo in
/// this case, just open it on the existing. you only need the rightmost botom auto split when there's
/// a terminal that gets opened when there's already a browser, and vice versa"): never a third column.
/// A shown chat leaves the pick to the app's measure (AgentBesidePlacement, RightColumnPlacement); a
/// chat no window shows gets the topology column's pane that already holds a browser.
@Suite(.timeLimit(.minutes(1))) struct AgentBesideKindPlacementTests {
    /// Workspace `ws-agent`: the agent chat (column 0) and a right column (column 1) of `right`.
    static func snapshot(right: [ControlPaneInfo], shown: Bool) -> ControlSnapshot {
        var snapshot = BrowserOpenSplitTests.snapshot()
        var chat = ControlTabInfo(id: "tab-chat", surface: "41", kind: "conversation", title: "Agent")
        chat.agentSessionID = "agent-1"
        var chatPane = ControlPaneInfo(id: "pane-chat", handle: "40", selectedTabID: "tab-chat", tabs: [chat])
        chatPane.column = 0
        var columns = right
        for index in columns.indices { columns[index].column = 1 }
        let screen = ControlScreenInfo(id: "screen-agent", handle: "42", panes: [chatPane] + columns)
        snapshot.topology.workspaces.append(ControlWorkspaceInfo(id: "ws-agent", handle: "43", name: "Agent", screens: [screen]))
        if shown {
            snapshot.topology.windows = [ControlWindowInfo(id: "win-1", workspaceID: "ws-agent", isKey: true, isVisible: true,
                                                           focusedPaneID: "pane-chat")]
        }
        return snapshot
    }

    static func pane(_ id: String, _ tabs: [(String, String)]) -> ControlPaneInfo {
        ControlPaneInfo(id: id, handle: id, selectedTabID: tabs.first?.0,
                        tabs: tabs.enumerated().map { ControlTabInfo(id: $1.0, surface: "5\($0)", kind: $1.1, title: $1.0) })
    }

    func request(right: [ControlPaneInfo], shown: Bool) async throws -> ControlActionRequest {
        let executor = OpenBrowserExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = Self.snapshot(right: right, shown: shown) }
        executor.router.withLock { $0 = router }
        _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "openBrowser", "args": ["url": "https://example.com"], "caller": ["agent_session": "agent-1"],
        ])).get()
        return try #require(executor.all.first)
    }

    @Test func aShownChatWithAColumnLetsTheAppPlaceTheBrowser() async throws {
        let request = try await request(right: [Self.pane("pane-term", [("tab-term", "terminal")])], shown: true)
        // The chat's own tab with newColumnBeside: AgentBesidePlacement measures the column and splits below
        // the terminal (or reuses a browser pane), as the chat header's Preview does.
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-chat"), "\(String(describing: request.target))")
        #expect(request.newColumnBeside)
        #expect(request.besideCaller)
    }

    @Test func aShownChatWithNoColumnStillMakesOne() async throws {
        let request = try await request(right: [], shown: true)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-chat"))
        #expect(request.newColumnBeside)
    }

    @Test func anUnshownChatReusesThePaneThatHoldsABrowser() async throws {
        let right = [Self.pane("pane-term", [("tab-term", "terminal")]), Self.pane("pane-web", [("tab-web", "browser")])]
        let request = try await request(right: right, shown: false)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-web"), "\(String(describing: request.target))")
        #expect(!request.newColumnBeside)
        #expect(request.besideCaller)
    }

    @Test func anUnshownChatWithTwoOtherPanesTakesTheLowest() async throws {
        let right = [Self.pane("pane-a", [("tab-a", "terminal")]), Self.pane("pane-b", [("tab-b", "terminal")])]
        let request = try await request(right: right, shown: false)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-b"))
        #expect(!request.newColumnBeside)
    }

    @Test func anUnshownChatWithOneOtherPaneKeepsItsTab() async throws {
        let request = try await request(right: [Self.pane("pane-term", [("tab-term", "terminal")])], shown: false)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-term"))
        #expect(!request.newColumnBeside)
    }

    @Test func identifyListsTheColumnWithItsKinds() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: OpenBrowserExecutor(), configuration: .loadTolerant)
        let right = [Self.pane("pane-web", [("tab-web", "browser")]), Self.pane("pane-term", [("tab-term", "terminal")])]
        router.snapshots.publish { $0 = Self.snapshot(right: right, shown: true) }
        let reply = try await router.handle(ControlRequest(id: "1", method: "system.identify", params: [
            "caller": ["agent_session": "agent-1"],
        ])).get()
        let beside = try #require(reply["beside"])
        #expect(beside["pane"] == "pane-web")
        #expect(beside["panes"] == [["id": "pane-web", "kinds": ["browser"]], ["id": "pane-term", "kinds": ["terminal"]]],
                "\(String(describing: beside["panes"]))")
    }
}
