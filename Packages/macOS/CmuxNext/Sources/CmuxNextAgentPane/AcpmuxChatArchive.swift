import Foundation

/// Archive from outside a chat pane (the sidebar's Priority view): `_acpmux/archive {sessionId,
/// archived: true}` on the daemon's socket, the chat menu's Archive (cx-jlzsf). acpmux's lists hide
/// the chat; Unarchive brings it back.
public nonisolated struct AcpmuxChatArchive: Sendable {
    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    @concurrent public func archive(sessionId: String) async throws {
        _ = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/archive",
                                              params: ["sessionId": sessionId, "archived": true], deadline: .seconds(2))
    }
}
