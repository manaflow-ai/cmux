import Foundation

/// Archive from outside a chat pane (the sidebar's Priority view): `_acpmux/archive {sessionId,
/// archived: true}` on the daemon's socket, the chat menu's Archive (cx-jlzsf). acpmux's lists hide
/// the chat; Unarchive brings it back.
public nonisolated struct AcpmuxChatArchive: Sendable {
    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    @concurrent public func archive(sessionId: String) async throws {
        _ = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/archive",
                                              params: ["sessionId": sessionId, "archived": true], deadline: AcpmuxEnvironment.answerDeadline)
    }

    /// Archives the chat an index key names (`<harness>:<session id>`); a key with no session id is a no-op.
    public func archive(chatKey: String) async throws {
        guard let session = AcpmuxChatKey.split(chatKey).session else { return }
        try await archive(sessionId: session)
    }
}

/// acpmux's chat index key, `<harness>:<session id>`: all a running chat is found by.
public nonisolated enum AcpmuxChatKey {
    public static func split(_ key: String) -> (harness: String?, session: String?) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts.first, parts.count == 2 && !parts[1].isEmpty ? parts[1] : nil)
    }
}
