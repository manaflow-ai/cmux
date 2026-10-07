import CmuxMobileWire

/// The Mac's control socket to `HostDO` (`/v1/wire/host/<host>`, B1). The app
/// supplies a WebSocket with subprotocols `cmux.wire.v1, bearer.<install token>`.
/// Frames are raw JSON objects: B1 adds `to`/`from` members on top of A0 frames.
public protocol HostControlSocket: Sendable {
    var frames: AsyncStream<JSONValue> { get }
    func send(_ frame: JSONValue) async throws
    func close() async
}
