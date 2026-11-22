import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// Lawrence 2026-10-09: one click on an All chats row (and the palette's and New Tab's Open
/// Chat) shows the chat in a NEW WORKSPACE as the ACP agent pane, never a terminal; a chat a tab
/// already resumes shows that tab instead of a duplicate. A chat acpmux cannot resume over ACP
/// yet starts a fresh agent chat in its folder on its harness. Open in Terminal (the row's menu)
/// is the only terminal path.
@MainActor
@Suite struct ChatOpenRouteTests {
    private func plan(_ result: [String: Any]) throws -> AcpmuxChatOpenPlan {
        try #require(AcpmuxChatOpenPlan(result: result))
    }

    private let adopt: [String: Any] = ["kind": "adopt", "cwd": "/p/app", "adopt": ["harness": "claude", "agentSessionId": "0a1b"],
                                        "sessionNew": ["cwd": "/p/app"]]
    private let opencode: [String: Any] = ["kind": "terminal", "cwd": "/p/my app",
                                           "terminal": ["argv": ["opencode", "-s", "ses 1"], "env": ["OPENCODE_DB": "/x.db"]]]

    @Test func anAdoptedChatOpensANewWorkspaceWithTheChat() throws {
        let route = ChatOpenRoute.route(try plan(adopt), chat: ChatOpenSubject(title: "Fix the build", harness: "claude-code"), openTab: { _ in nil })
        #expect(route == .newWorkspace(name: "Fix the build", cwd: "/p/app",
                                       seed: AgentPaneSeed(cwd: "/p/app", adopt: AgentPaneAdopt(harness: "claude", agentSessionId: "0a1b")),
                                       command: nil, env: [:]))
    }

    @Test func aChatAlreadyOpenFocusesItsTabInsteadOfADuplicate() throws {
        var asked: [AgentPaneAdopt] = []
        let route = ChatOpenRoute.route(try plan(adopt), chat: ChatOpenSubject(title: "Fix the build"), openTab: { asked.append($0); return "tab-7" })
        #expect(route == .reveal(tab: "tab-7"))
        #expect(asked == [AgentPaneAdopt(harness: "claude", agentSessionId: "0a1b")])
    }

    /// A chat acpmux would resume in a terminal (OpenCode here) opens the agent pane instead: a
    /// fresh ACP chat in the chat's folder on its harness, never a terminal.
    @Test func aChatWithoutACPResumeOpensAFreshAgentChatNotATerminal() throws {
        let route = ChatOpenRoute.route(try plan(opencode), chat: ChatOpenSubject(title: "Bench", harness: "opencode", cwd: "/p/my app"),
                                        openTab: { _ in "never" })
        #expect(route == .newWorkspace(name: "Bench", cwd: "/p/my app", seed: AgentPaneSeed(cwd: "/p/my app", harness: "opencode"),
                                       command: nil, env: [:]))
        let readOnly = try plan(["kind": "readOnly", "readOnly": ["path": "/h/.amp/t.json"]])
        let amp = ChatOpenRoute.route(readOnly, chat: ChatOpenSubject(title: "Old", harness: "amp", cwd: "/p/x"), openTab: { _ in nil })
        #expect(amp == .newWorkspace(name: "Old", cwd: "/p/x", seed: AgentPaneSeed(cwd: "/p/x", harness: nil), command: nil, env: [:]))
    }

    /// Open in Terminal: the harness's own resume command (argv quoted), in a new workspace.
    @Test func openInTerminalRunsTheResumeCommand() throws {
        let terminal = ChatOpenRoute.route(try plan(opencode), chat: ChatOpenSubject(title: nil, harness: "opencode"), inTerminal: true,
                                           openTab: { _ in "never" })
        #expect(terminal == .newWorkspace(name: nil, cwd: "/p/my app", seed: nil, command: "opencode -s 'ses 1'", env: ["OPENCODE_DB": "/x.db"]))
        let claude = ChatOpenRoute.route(try plan(adopt), chat: ChatOpenSubject(title: "T", harness: "claude-code"), inTerminal: true,
                                         openTab: { _ in "tab" })
        #expect(claude == .newWorkspace(name: "T", cwd: "/p/app", seed: nil, command: "claude --resume 0a1b", env: [:]))
    }
}
