import Foundation

extension AcpmuxEnvironment {
    /// The open plan of one device-wide chat from this daemon
    /// (`_acpmux/chat_open`, ALL-CHATS-ON-DEVICE S5); `cwd` is a folder the
    /// person picked when the plan asked for one. Nil when the daemon's
    /// answer is not a plan this build reads.
    public nonisolated func chatOpenPlan(key: String, cwd: String? = nil) async throws -> AcpmuxChatOpenPlan? {
        try await AcpmuxStatusClient.chatOpen(environment: self, key: key, cwd: cwd)
    }

    /// The past turns of one device-wide chat from this daemon (`_acpmux/chat_transcript`,
    /// cx-khns1), shown read-only before the chat can resume.
    public nonisolated func chatTranscript(key: String) async throws -> [AgentPanePastTurn] {
        try await AcpmuxStatusClient.chatTranscript(environment: self, key: key)
    }
}
