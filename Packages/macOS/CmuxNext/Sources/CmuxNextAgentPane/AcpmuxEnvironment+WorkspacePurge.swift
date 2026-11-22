public import Foundation

extension AcpmuxEnvironment {
    /// Stops and deletes every chat this daemon recorded for cmux workspace `key` (its sub-sessions,
    /// forks, and agents started from its terminals included), with the transcripts those chats wrote
    /// (`_acpmux/workspace_purge`, cmux-tui acpmux `server/chats/workspace_purge.rs`). acpmux decides which
    /// chats those are; an incognito workspace's close sends this. It never starts a daemon.
    public nonisolated func purgeWorkspace(key: String, deadline: Duration = .seconds(5)) async throws {
        _ = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/workspace_purge",
                                              params: ["workspaceId": key], deadline: deadline)
    }
}
