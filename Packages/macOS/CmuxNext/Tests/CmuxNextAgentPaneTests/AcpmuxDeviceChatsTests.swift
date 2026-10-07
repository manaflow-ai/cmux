@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The daemon's device-wide chat index (`_acpmux/chats`): every harness's chats on this Mac,
/// newest first, as the palette's Agent Chats page lists them.
struct AcpmuxDeviceChatsTests {
    static func chat(_ session: String, harness: String = "claude-code", title: String? = "Fix the flaky tests",
                     cwd: String? = "/Users/me/repo", updatedMs: Double = 1_800_000_000_000, resume: String = "adopt",
                     archived: Bool = false) -> [String: Any] {
        var chat: [String: Any] = ["key": "\(harness):\(session)", "harness": harness, "sessionId": session,
                                   "updatedMs": updatedMs, "messageCount": 12, "archived": archived,
                                   "resume": ["kind": resume], "accounts": [], "roots": ["r1"]]
        if let title { chat["title"] = title }
        if let cwd { chat["cwd"] = cwd }
        return chat
    }

    @Test func aPageKeepsItsOrderAndReadsEachChat() {
        let chats = AcpmuxDeviceChat.page(["ready": true, "enabled": true, "nextCursor": NSNull(), "chats": [
            Self.chat("0a1b", title: "Fix the flaky tests"),
            Self.chat("01999a", harness: "codex", title: nil, cwd: nil, updatedMs: 5, resume: "adopt"),
            Self.chat("ses_1", harness: "opencode", resume: "argv"),
        ]])
        #expect(chats.map(\.id) == ["claude-code:0a1b", "codex:01999a", "opencode:ses_1"])
        #expect(chats[0] == AcpmuxDeviceChat(id: "claude-code:0a1b", harness: "claude-code", sessionID: "0a1b",
                                              title: "Fix the flaky tests", cwd: "/Users/me/repo",
                                              updatedMs: 1_800_000_000_000, messageCount: 12, resume: "adopt"))
        #expect(chats[1].title == nil && chats[1].cwd == nil)
        #expect(chats[2].resume == "argv")
    }

    @Test func archivedAndMalformedChatsAreLeftOut() {
        var keyless = Self.chat("x")
        keyless["key"] = nil
        let chats = AcpmuxDeviceChat.page(["chats": [Self.chat("old", archived: true), keyless, Self.chat("kept")]])
        #expect(chats.map(\.sessionID) == ["kept"])
    }

    /// Recents rows carry the harness's session id, so the device rows can leave those chats out.
    @Test func aRecentChatKnowsItsHarnessSessionID() {
        var recents = AcpmuxRecentChats()
        var summary = AcpmuxRecentChatsTests.session("s1", updatedAt: 1, name: "deploy fix")
        summary["agentSessionId"] = "0a1b"
        recents.reset(["sessions": [summary, AcpmuxRecentChatsTests.session("s2", updatedAt: 2)]])
        #expect(recents.newest(2).map(\.agentSessionID) == [nil, "0a1b"])
    }
}
