import Foundation

extension AcpmuxEnvironment {
    /// The open plan of one device-wide chat from this daemon
    /// (`_acpmux/chat_open`, ALL-CHATS-ON-DEVICE S5); `cwd` is a folder the
    /// person picked when the plan asked for one. Nil when the daemon's
    /// answer is not a plan this build reads.
    public nonisolated func chatOpenPlan(key: String, cwd: String? = nil) async throws -> AcpmuxChatOpenPlan? {
        try await AcpmuxStatusClient.chatOpen(socketPath: socketPath, key: key, cwd: cwd)
    }

    /// The past turns of one device-wide chat from this daemon (`_acpmux/chat_transcript`,
    /// cx-khns1), shown read-only before the chat can resume.
    public nonisolated func chatTranscript(key: String) async throws -> [AgentPanePastTurn] {
        try await AcpmuxStatusClient.chatTranscript(socketPath: socketPath, key: key)
    }

    /// Forks a terminal agent's session `agentSessionId` of `harness` through the harness's ACP
    /// agent (`_acpmux/chat_fork`): Fork Conversation of an agent whose CLI has no fork (Muse).
    /// Returns the fork's own session id, which the agent's CLI then resumes.
    ///
    /// - Throws: acpmux's reason when the harness has no ACP agent here or its agent cannot fork.
    public nonisolated func forkChat(harness: String, agentSessionId: String, cwd: String?) async throws -> String {
        do {
            return try await AcpmuxStatusClient.chatFork(socketPath: socketPath, harness: harness, agentSessionId: agentSessionId, cwd: cwd)
        } catch AcpmuxStatusClient.Failure.rpc(let reason) {
            // acpmux's own reason ("muse cannot fork a chat: …") is what the person reads.
            throw NSError(domain: "acpmux.chat_fork", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }
}
