@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// A Chief's turn (`caller.home_chat`, set by the Chief host) opens its tabs
/// beside the Home chat when the app does not know its agent session: the
/// local Chief's turn sessions and the Cloud Chief's (on a VM, through the
/// Mac app relay) have no chat tab of their own in the Mac's topology.
@Suite(.timeLimit(.minutes(1))) struct HomeChatCallerTests {
    /// Home: the docked chat (column 0, left dock, page `home-dock`) and the
    /// right column (column 1) with one browser tab. ws-1 is shown.
    static func snapshot() -> ControlSnapshot {
        var snapshot = BrowserOpenSplitTests.snapshot()
        var chat = ControlTabInfo(id: "tab-home", surface: "31", kind: "conversation", title: "Home")
        chat.page = "home-dock"
        var dock = ControlPaneInfo(id: "pane-home", handle: "8", selectedTabID: "tab-home", tabs: [chat])
        dock.column = 0
        dock.dock = "left"
        var right = ControlPaneInfo(id: "pane-right", handle: "9", selectedTabID: "tab-right",
                                    tabs: [ControlTabInfo(id: "tab-right", surface: "32", kind: "browser", title: "Docs")])
        right.column = 1
        var home = ControlWorkspaceInfo(id: "ws-home", handle: "10", name: "Home",
                                        screens: [ControlScreenInfo(id: "screen-home", handle: "11", panes: [dock, right])])
        home.kind = "home"
        snapshot.topology.workspaces.insert(home, at: 0)
        return snapshot
    }

    func makeRouter(_ executor: OpenBrowserExecutor) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = Self.snapshot() }
        executor.router.withLock { $0 = router }
        return router
    }

    func run(_ router: ControlRouter, caller: JSONValue) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "openBrowser", "args": ["url": "https://example.com"], "caller": caller,
        ]))
    }

    @Test func aChiefTurnTheAppDoesNotKnowOpensBesideTheHomeChat() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        _ = try await run(router, caller: ["agent_session": "turn-on-a-vm", "home_chat": true]).get()
        let request = try #require(executor.all.first)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-right"), "beside the Home chat: \(String(describing: request.target))")
        #expect(request.besideCaller)
    }

    @Test func homeChatAloneIsACaller() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        _ = try await run(router, caller: ["home_chat": true]).get()
        let request = try #require(executor.all.first)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-right"))
    }

    @Test func withoutHomeChatAnUnknownSessionIsRefused() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        let result = await run(router, caller: ["agent_session": "turn-on-a-vm"])
        let failure = try #require(result.failure)
        #expect(failure.code == "caller_unavailable")
        #expect(executor.all.isEmpty)
    }

    @Test func identifyReportsTheHomeChatColumnAsBeside() async throws {
        let router = makeRouter(OpenBrowserExecutor())
        let reply = try await router.handle(ControlRequest(id: "1", method: "system.identify", params: [
            "caller": ["agent_session": "turn-on-a-vm", "home_chat": true],
        ])).get()
        #expect(reply["beside"]?["pane"] == "pane-right", "\(String(describing: reply["beside"]))")
        #expect(reply["caller"]?["tab"] == "tab-home")
    }
}
