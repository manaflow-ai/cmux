import Foundation

extension AcpmuxEnvironment {
    /// The open plan of one device-wide chat from this daemon
    /// (`_acpmux/chat_open`, ALL-CHATS-ON-DEVICE S5); `cwd` is a folder the
    /// person picked when the plan asked for one. Nil when the daemon's
    /// answer is not a plan this build reads.
    public nonisolated func chatOpenPlan(key: String, cwd: String? = nil) async throws -> AcpmuxChatOpenPlan? {
        try await AcpmuxStatusClient.chatOpen(socketPath: socketPath, key: key, cwd: cwd)
    }
}
