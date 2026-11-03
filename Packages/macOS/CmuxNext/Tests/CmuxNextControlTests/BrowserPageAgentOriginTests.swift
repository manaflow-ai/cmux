@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// The agent cursor's tag says who drives and where (user, 2026-10-20:
/// "Chief · <workspace name>" or "a201 · <workspace/terminal title>"), and a
/// click on it goes there. The CLI sends its `caller` with each input, so the
/// app knows the terminal or chat the agent works from.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageAgentOriginTests {
    typealias Engine = BrowserPageAgentInputTests.AnnouncingEngine

    func install() -> (ControlRouter, Engine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let engine = Engine(BrowserPageAgentInputTests.field)
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = HomeChatCallerTests.snapshot()
        let index = snapshot.topology.workspaces.firstIndex { $0.id == "ws-1" }!
        snapshot.topology.workspaces[index].title = "cursor-gallery"
        snapshot.topology.workspaces[index].screens[0].panes[0].tabs[0].terminalID = "term-7"
        let page = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Form", url: "https://example.com/")
        snapshot.topology.workspaces[index].screens[0].panes[0].tabs.append(page)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func click(_ router: ControlRouter, _ extra: [String: JSONValue]) async throws {
        var params: [String: JSONValue] = ["tab": "tab_0123abcd", "selector": "#go"]
        params.merge(extra) { $1 }
        _ = try await router.handle(ControlRequest(method: "browser.page.click", params: params)).get()
    }

    @Test func anAgentsInputNamesTheWorkspaceItWorksFrom() async throws {
        let (router, engine) = install()
        try await click(router, ["agent": "a201", "caller": ["terminal_id": "term-7"]])
        let input = try #require(engine.inputs.last)
        #expect(input.agent == "a201")
        #expect(input.origin == BrowserPageAgentOrigin(isChief: false, workspaceID: "ws_aaa", workspaceName: "cursor-gallery",
                                                      tabID: "tab-1"))
    }

    @Test func aChiefTurnIsTheChiefInTheHomeWorkspace() async throws {
        let (router, engine) = install()
        try await click(router, ["agent": "Claude", "caller": ["home_chat": true]])
        let origin = try #require(engine.inputs.last?.origin)
        #expect(origin.isChief)
        #expect(origin.workspaceName == "Home")
        #expect(origin.tabID == "tab-home", "a click on the tag goes to the Chief's chat")
    }

    @Test func everyInputVerbCarriesTheOrigin() async throws {
        let (router, engine) = install()
        let caller: JSONValue = ["terminal_id": "term-7"]
        try await click(router, ["caller": caller])
        _ = try await router.handle(ControlRequest(method: "browser.page.press", params: [
            "tab": "tab_0123abcd", "key": "Enter", "caller": caller,
        ])).get()
        _ = try await router.handle(ControlRequest(method: "browser.page.hover", params: [
            "tab": "tab_0123abcd", "selector": "#go", "caller": caller,
        ])).get()
        #expect(engine.inputs.count == 3)
        #expect(engine.inputs.allSatisfy { $0.origin?.tabID == "tab-1" }, "\(engine.inputs)")
    }

    @Test func withoutACallerThereIsNoOrigin() async throws {
        let (router, engine) = install()
        try await click(router, ["agent": "a201"])
        #expect(engine.inputs.last?.origin == nil)
        try await click(router, ["caller": ["terminal_id": "term-gone"]])
        #expect(engine.inputs.last?.origin == nil, "a caller the topology does not show")
    }
}
