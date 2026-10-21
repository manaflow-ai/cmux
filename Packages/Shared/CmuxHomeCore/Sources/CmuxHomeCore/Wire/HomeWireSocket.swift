public import Foundation

/// One WebSocket to a `cmux.wire/1` stream (`/v1/wire/user` or
/// `/v1/wire/conv/<id>`, subprotocol `cmux.wire.v1`). Text frames only.
/// Production wraps `URLSessionWebSocketTask`; tests pass a fake whose
/// frames they push and whose sent frames they read.
public protocol HomeWireSocket: AnyObject, Sendable {
    /// Sends one text frame.
    func send(_ text: String) async throws
    /// The next text frame. Throws when the socket ended.
    func receive() async throws -> String
    /// Closes the socket (idempotent).
    func close()
    /// The close code the server ended the socket with (4401: the token
    /// expired), or nil while open or when none came.
    var closeCode: Int? { get }
    /// The HTTP status of a refused upgrade (401, 403, 404), else nil.
    var upgradeStatus: Int? { get }
    /// Sends a protocol ping; true when the pong came back.
    func ping() async -> Bool
}
