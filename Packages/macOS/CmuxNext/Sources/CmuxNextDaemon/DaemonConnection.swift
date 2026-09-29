public import Foundation

/// Placeholder cmux-tui connection. It owns no socket yet: `events()` reports
/// a disconnect and `send` throws. The daemon-client agent replaces the body
/// (socket, framing, snapshot resync) behind the same `DaemonConnecting` API.
public actor DaemonConnection: DaemonConnecting {
    public let endpoint: DaemonEndpoint

    public init(endpoint: DaemonEndpoint) {
        self.endpoint = endpoint
    }

    public func events() -> AsyncStream<DaemonEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DaemonEvent.self, bufferingPolicy: .unbounded)
        continuation.yield(.disconnected(reason: "daemon client not implemented"))
        continuation.finish()
        return stream
    }

    public func output(for terminal: TerminalID) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.finish()
        return stream
    }

    public func send(_ command: DaemonCommand) async throws {
        throw DaemonError.notConnected
    }
}
