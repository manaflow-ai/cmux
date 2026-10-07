import CmuxNextAgentPane
import CmuxNextOnboarding
import Foundation
import Testing
@testable import CmuxNextApp

/// The palette's Agent Chats page lists every Claude Code and Codex chat on this Mac, not only the
/// eight Recents, and opens each as the onboarding chats step resumes it (cx-heu.3).
@MainActor @Suite struct AgentChatsDevicePageTests {
    private func chat(_ session: String, harness: String = "claude-code", cwd: String? = "/Users/me/repo",
                      resume: String = "adopt") -> AcpmuxDeviceChat {
        AcpmuxDeviceChat(id: "\(harness):\(session)", harness: harness, sessionID: session, title: "Title \(session)",
                         cwd: cwd, updatedMs: 1_800_000_000_000, messageCount: 4, resume: resume)
    }

    @Test func claudeAndCodexChatsBecomeOnboardingChats() {
        let chats = AgentChatsPalettePage.resumable([chat("0a1b"), chat("01999a", harness: "codex")], shown: [])
        #expect(chats == [
            AgentChat(sessionID: "0a1b", app: .claudeCode, folder: URL(fileURLWithPath: "/Users/me/repo", isDirectory: true),
                      title: "Title 0a1b", prompts: 4, lastActive: Date(timeIntervalSince1970: 1_800_000_000)),
            AgentChat(sessionID: "01999a", app: .codex, folder: URL(fileURLWithPath: "/Users/me/repo", isDirectory: true),
                      title: "Title 01999a", prompts: 4, lastActive: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
        #expect(chats.map(\.adoptHarness) == ["claude", "codex"])
    }

    /// A chat Recents already shows, one with no folder, one acpmux can't adopt, and one in a
    /// harness it doesn't adopt are not listed twice or as a dead end.
    @Test func chatsItCannotOpenOrRecentsShowAreLeftOut() {
        let chats = AgentChatsPalettePage.resumable([
            chat("in-recents"),
            chat("no-folder", cwd: nil),
            chat("terminal-only", resume: "argv"),
            chat("ses_1", harness: "opencode"),
            chat("kept"),
        ], shown: ["in-recents"])
        #expect(chats.map(\.sessionID) == ["kept"])
    }
}
