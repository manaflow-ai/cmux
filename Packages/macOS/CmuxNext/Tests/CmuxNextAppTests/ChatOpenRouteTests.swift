import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// Lawrence 2026-10-09: one click on an All chats row (and the palette's and New Tab's Open
/// Chat) shows the chat in a NEW WORKSPACE; a chat a tab already resumes shows that tab
/// instead of a duplicate workspace.
@MainActor
@Suite struct ChatOpenRouteTests {
    private func plan(_ result: [String: Any]) throws -> AcpmuxChatOpenPlan {
        try #require(AcpmuxChatOpenPlan(result: result))
    }

    private let adopt: [String: Any] = ["kind": "adopt", "cwd": "/p/app", "adopt": ["harness": "claude", "agentSessionId": "0a1b"],
                                        "sessionNew": ["cwd": "/p/app"]]

    @Test func anAdoptedChatOpensANewWorkspaceWithTheChat() throws {
        let route = ChatOpenRoute.route(try plan(adopt), title: "Fix the build", openTab: { _ in nil })
        #expect(route == .newWorkspace(name: "Fix the build", cwd: "/p/app",
                                       seed: AgentPaneSeed(cwd: "/p/app", adopt: AgentPaneAdopt(harness: "claude", agentSessionId: "0a1b")),
                                       command: nil, env: [:]))
    }

    @Test func aChatAlreadyOpenFocusesItsTabInsteadOfADuplicate() throws {
        var asked: [AgentPaneAdopt] = []
        let route = ChatOpenRoute.route(try plan(adopt), title: "Fix the build", openTab: { asked.append($0); return "tab-7" })
        #expect(route == .reveal(tab: "tab-7"))
        #expect(asked == [AgentPaneAdopt(harness: "claude", agentSessionId: "0a1b")])
    }

    @Test func aTerminalResumeOpensANewWorkspaceRunningTheQuotedArgv() throws {
        let terminal = try plan(["kind": "terminal", "cwd": "/p/my app",
                                 "terminal": ["argv": ["opencode", "-s", "ses 1"], "env": ["OPENCODE_DB": "/x.db"]]])
        let route = ChatOpenRoute.route(terminal, title: nil, openTab: { _ in "never" })
        #expect(route == .newWorkspace(name: nil, cwd: "/p/my app", seed: nil, command: "opencode -s 'ses 1'", env: ["OPENCODE_DB": "/x.db"]))
    }
}
