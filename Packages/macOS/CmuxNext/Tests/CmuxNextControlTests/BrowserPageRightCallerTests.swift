@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Lawrence 2026-11-12: `cmux browser right <verb>` always used the column right of the Home chat, so every
/// workspace agent that ran it filled the Chief's workspace with its tabs. The column is the caller's: a Chief
/// turn (`caller.home_chat`) or a call with no caller keeps Home's; an agent in a workspace of its own gets its
/// tab beside itself (its helper column, else a new column right of it), with the same leases, and never Home.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageRightCallerTests {
    static let worker: JSONValue = ["agent_session": "agent-1"]

    /// Home (the chat dock and its right column, BrowserPageRightTests) and `ws-work` (`ws_work`): an agent
    /// chat (session `agent-1`, column 0) with `right` in column 1.
    static func snapshot(right: [ControlPaneInfo] = []) -> ControlSnapshot {
        var snapshot = BrowserPageRightTests.homeSnapshot()
        var chat = ControlTabInfo(id: "tab_work", surface: "70", kind: "conversation", title: "Worker")
        chat.agentSessionID = "agent-1"
        var pane = ControlPaneInfo(id: "pane_work", handle: "71", selectedTabID: "tab_work", tabs: [chat])
        pane.column = 0
        var columns = right
        for index in columns.indices { columns[index].column = 1 }
        var workspace = ControlWorkspaceInfo(id: "work-key", handle: "72", name: "Work",
                                             screens: [ControlScreenInfo(id: "screen_work", handle: "73", panes: [pane] + columns)])
        workspace.resourceID = "ws_work"
        snapshot.topology.workspaces.append(workspace)
        return snapshot
    }

    func homeTabs(_ router: ControlRouter) -> [String] {
        router.snapshots.current.topology.workspaces.first { $0.kind == "home" }?.panes.flatMap(\.tabs).map(\.id) ?? []
    }

    @Test func aWorkspaceAgentsTabOpensBesideItAndNeverInHome() async throws {
        let suite = BrowserPageRightTests()
        let (router, executor) = suite.install(Self.snapshot())
        let home = homeTabs(router)
        let opened = try await suite.right(router, ["agent": "Worker", "url": "https://example.com/", "caller": Self.worker]).get()
        #expect(opened["workspace"] == "ws_work", "the agent's own workspace, not Home: \(opened)")
        #expect(opened["pane"] == "pane_work")
        #expect(opened["created"] == true)
        #expect(opened["navigated"] == true)
        let run = try #require(executor.last)
        #expect(run.actionID == "openBrowser")
        // No helper column: its own chat with newColumnBeside, which the app moves into a new column right of it.
        #expect(run.target == ControlTargetRef(kind: "tab", id: "tab_work"), "\(String(describing: run.target))")
        #expect(run.newColumnBeside)
        #expect(run.besideCaller)
        #expect(run.focus == false)
        #expect(run.arguments["profile"]?.json == "agent")
        #expect(homeTabs(router) == home, "Home got a tab")

        // Its own tab from now on: the next verb runs on it, and nothing more opens.
        let again = try await suite.right(router, ["agent": "Worker", "verb": "browser.page.click", "caller": Self.worker]).get()
        #expect(again["tab"] == opened["tab"])
        #expect(again["created"] == false)
        #expect(executor.count == 1)
    }

    @Test func aWorkspaceAgentUsesItsHelperColumnWithTheSameRulesForThePersonsTab() async throws {
        let person = ControlTabInfo(id: "tab_docs", surface: "74", kind: "browser", title: "Docs", url: "https://docs.example.com/")
        let right = [ControlPaneInfo(id: "pane_helper", handle: "75", selectedTabID: "tab_docs", tabs: [person])]
        let suite = BrowserPageRightTests()
        let (router, executor) = suite.install(Self.snapshot(right: right))
        // The shown tab of its helper column is the person's: it reads it, and never drives it unasked.
        let read = try await suite.right(router, ["agent": "Worker", "verb": "browser.page.snapshot", "caller": Self.worker]).get()
        #expect(read["tab"] == "tab_docs")
        #expect(read["shared"] == true)
        #expect(read["workspace"] == "ws_work")
        #expect(await suite.right(router, ["agent": "Worker", "verb": "browser.page.click", "caller": Self.worker]).failure?.code == "user_tab")
        // Its own tab opens in that column, not in Home's.
        let home = homeTabs(router)
        let opened = try await suite.right(router, ["agent": "Worker", "url": "https://example.com/", "caller": Self.worker]).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab_docs"))
        #expect(opened["pane"] == "pane_helper")
        #expect(opened["workspace"] == "ws_work")
        #expect(homeTabs(router) == home)
    }

    @Test(arguments: [["home_chat": true], ["agent_session": "turn-on-a-vm", "home_chat": true]] as [JSONValue])
    func aChiefTurnStillUsesTheColumnRightOfTheHomeChat(caller: JSONValue) async throws {
        let suite = BrowserPageRightTests()
        let (router, executor) = suite.install(Self.snapshot())
        let opened = try await suite.right(router, ["agent": "Chief", "url": "https://cmux.com/", "caller": caller]).get()
        #expect(opened["workspace"] == "ws_home")
        #expect(opened["pane"] == .string(BrowserPageRightTests.rightPane))
        #expect(["tab_markdown", "tab_user"].contains(executor.last?.target?.id ?? ""))
        #expect(executor.last?.besideCaller == false)
    }

    @Test func anAgentTheTopologyDoesNotShowGetsNoColumn() async throws {
        let suite = BrowserPageRightTests()
        let (router, executor) = suite.install(Self.snapshot())
        let refused = await suite.right(router, ["agent": "Worker", "url": "https://example.com/", "caller": ["agent_session": "gone"]])
        #expect(refused.failure?.code == "caller_unavailable")
        #expect(executor.count == 0)
    }
}
