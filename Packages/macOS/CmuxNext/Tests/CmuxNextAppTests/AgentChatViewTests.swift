@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// View Only: an All chats row's View Only item (`chats.watch`) and `cmux agent view <chat>`
/// (`agentChat.view`) open a Claude Code or Codex chat through the same opener, which asks acpmux
/// to show it without running it (`adopt.watch`, acpmux `hub/watch.rs`).
@MainActor @Suite
struct AgentChatViewTests {
    private static let key = "claude-code:0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    private static let subject = ChatOpenSubject(title: "Fix the build", harness: "claude-code", sessionID: nil, cwd: "/tmp", key: key)

    private static func adoptPlan() throws -> AcpmuxChatOpenPlan {
        try #require(AcpmuxChatOpenPlan(result: [
            "kind": "adopt", "cwd": "/tmp", "adopt": ["harness": "claude", "agentSessionId": "x"], "sessionNew": ["cwd": "/tmp"],
        ]))
    }

    @Test func viewOnlyAsksAcpmuxToWatchTheChat() throws {
        var opened: [AgentPaneAdopt] = []
        _ = ChatOpenRoute.route(try Self.adoptPlan(), chat: Self.subject, watch: true, openTab: { opened.append($0); return "tab" })
        _ = ChatOpenRoute.route(try Self.adoptPlan(), chat: Self.subject, openTab: { opened.append($0); return "tab" })
        #expect(opened.map(\.watch) == [true, nil])
        #expect(opened.first?.reply["watch"] as? Bool == true)
        #expect(opened.last?.reply["watch"] == nil, "a chat the tab runs sends no watch flag")
    }

    /// Open resumes outside chats to steer by default (Leo 2026-10-21); the Debug toggle makes it View
    /// Only, and only a Claude Code or Codex chat is ever watched: another harness's chat opens as it always did.
    @Test func openIsViewOnlyForClaudeCodeAndCodexOnly() throws {
        #expect(AgentPaneTunables.openOutsideChatsViewOnly.descriptor.key == "agent.openOutsideChatsViewOnly")
        #expect(AgentPaneTunables.all.contains { $0.key == "agent.openOutsideChatsViewOnly" })
        #expect(AgentPaneTunables.openOutsideChatsViewOnly.defaultValue == false, "Open steers an outside chat by default")
        let opencode = try #require(AcpmuxChatOpenPlan(result: [
            "kind": "adopt", "cwd": "/tmp", "adopt": ["harness": "opencode", "agentSessionId": "x"], "sessionNew": ["cwd": "/tmp"],
        ]))
        var opened: [AgentPaneAdopt] = []
        _ = ChatOpenRoute.route(opencode, chat: Self.subject, watch: true, openTab: { opened.append($0); return "tab" })
        #expect(opened.map(\.watch) == [nil])
    }

    /// A profile is named freely (`claude-work`, a subrouter account): the plan's family, not the
    /// profile's name, says it is a Claude Code chat, so it still opens View Only.
    @Test func viewOnlyGoesByFamilyNotProfileName() throws {
        let plan = try #require(AcpmuxChatOpenPlan(result: [
            "kind": "adopt", "cwd": "/tmp", "family": "claude",
            "adopt": ["harness": "claude-work", "agentSessionId": "x"], "sessionNew": ["cwd": "/tmp"],
        ]))
        var opened: [AgentPaneAdopt] = []
        _ = ChatOpenRoute.route(plan, chat: Self.subject, watch: true, openTab: { opened.append($0); return "tab" })
        #expect(opened.map(\.watch) == [true])
    }

    @Test func theRowMenuAndTheActionTakeOnlyChatKeys() {
        let request = AgentPaneRequest(body: ["method": "chats.watch", "params": ["key": Self.key]])
        guard case .watchChat(let key) = request else { Issue.record("\(request)"); return }
        #expect(key == Self.key)
        #expect(ChatOpenSubject.isWatchable(key: Self.key))
        #expect(ChatOpenSubject.isWatchable(key: "codex:0199a1b2"))
        for bad in ["", "claude-code:", "opencode:x", "show", "/tmp/x.jsonl", "codex:" + String(repeating: "a", count: 600)] {
            #expect(!ChatOpenSubject.isWatchable(key: bad), "\(bad)")
        }
    }
}
