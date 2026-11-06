import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileShell

struct TerminalCommandSuggestionsLoaderTests {
    private func session(_ id: String, workspace: String = "workspace", terminal: String = "terminal",
                         agent: ChatAgentKind = .claude, state: ChatAgentState = .idle) -> ChatSessionDescriptor {
        .init(id: id, agentKind: agent, workspaceID: workspace, terminalID: terminal, state: state)
    }

    private func message(_ seq: Int, _ text: String, role: ChatRole = .agent) -> ChatMessage {
        .init(id: "\(seq)", seq: seq, role: role, timestamp: .distantPast, kind: .prose(.init(text: text)))
    }

    @Test func loadsOnlyTheBoundClaudeSession() async throws {
        let sessions = [session("other-workspace", workspace: "other"), session("other-terminal", terminal: "other"),
                        session("codex", agent: .codex), session("ended", state: .ended), session("correct")]
        let page = ChatHistoryPage(messages: [message(1, "! bash ~/scripts/complete-script.sh")], hasMore: false)
        let loader = TerminalCommandSuggestionsLoader(sessions: { requested in
            #expect(requested == "workspace")
            return sessions
        }, history: { id, _ in
            #expect(id == "correct")
            return page
        })
        let commands = try await loader.load(workspaceID: "workspace", terminalID: "terminal")
        #expect(commands.map(\.text) == ["! bash ~/scripts/complete-script.sh"])
        #expect(commands.map(\.sessionID) == ["correct"])
    }

    @Test func preservesOriginalTextAndIgnoresUserMessages() async throws {
        let sessions = [session("session")]
        let command = "! bash ~/scripts/" + String(repeating: "long-path/", count: 20) + "run.sh"
        let page = ChatHistoryPage(messages: [message(1, "! old"), message(2, command),
                                              message(3, "! user-input", role: .user), message(4, command)], hasMore: false)
        let loader = TerminalCommandSuggestionsLoader(sessions: { _ in sessions }, history: { _, _ in page })
        #expect(try await loader.load(workspaceID: "workspace", terminalID: "terminal").map(\.text) == [command, "! old"])
    }

    @Test func rejectsUnboundAndEndedSessions() async throws {
        let sessions = [session("other", terminal: "other"), session("ended", state: .ended)]
        let loader = TerminalCommandSuggestionsLoader(sessions: { _ in sessions }, history: { _, _ in
            Issue.record("Unbound history must never be requested")
            return .init(messages: [], hasMore: false)
        })
        await #expect(throws: TerminalCommandSuggestionsError.noSession) {
            try await loader.load(workspaceID: "workspace", terminalID: "terminal")
        }
    }

    @Test func loadsOlderOriginalCommandsWithAProgressingCursor() async throws {
        let sessions = [session("session")]
        let newest = ChatHistoryPage(messages: [message(100, "! newer")], hasMore: true)
        let older = ChatHistoryPage(messages: [message(50, "! older")], hasMore: false)
        let loader = TerminalCommandSuggestionsLoader(sessions: { _ in sessions }, history: { _, cursor in
            if let cursor { #expect(cursor == 100); return older }
            return newest
        })
        #expect(try await loader.load(workspaceID: "workspace", terminalID: "terminal").map(\.text) == ["! newer", "! older"])
    }
}
