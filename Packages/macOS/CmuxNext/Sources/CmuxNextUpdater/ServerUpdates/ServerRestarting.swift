import Foundation

/// Restarts one server and returns its successor's handshake. The app implements it (a cmux-tui
/// handoff that keeps terminals, an acpmux shutdown and start); tests pass a fake.
@MainActor
public protocol ServerRestarting: AnyObject {
    /// Restarts `kind` on `host` and returns the new server's handshake.
    /// - Throws: When the restart failed or the server did not come back.
    func restart(_ kind: ServerKind, host: ServerHost) async throws -> ServerHandshake
}
