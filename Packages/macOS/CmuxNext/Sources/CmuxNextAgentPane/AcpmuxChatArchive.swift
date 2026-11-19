import Foundation

/// Archive and Restore from outside a chat pane (the sidebar's Priority view and its Archived fold):
/// `_acpmux/archive {sessionId, archived}` on the daemon's socket, the chat menu's Archive and
/// Unarchive (cx-jlzsf). acpmux's lists hide an archived chat; Restore brings it back.
public nonisolated struct AcpmuxChatArchive: Sendable {
    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    @concurrent public func archive(sessionId: String) async throws {
        try await set(sessionId: sessionId, archived: true)
    }

    /// Removes the chat's `archived` tag: it lists again where it listed before.
    @concurrent public func unarchive(sessionId: String) async throws {
        try await set(sessionId: sessionId, archived: false)
    }

    @concurrent public func set(sessionId: String, archived: Bool) async throws {
        _ = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/archive",
                                              params: ["sessionId": sessionId, "archived": archived], deadline: AcpmuxEnvironment.answerDeadline)
    }
}
