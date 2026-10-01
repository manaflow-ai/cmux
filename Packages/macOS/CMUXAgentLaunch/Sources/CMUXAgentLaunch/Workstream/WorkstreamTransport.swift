import Foundation

/// Abstracts the delivery path for workstream events and actions so the
/// store can be wired to the cmux Unix socket on macOS, an in-memory pipe
/// in tests, or a relay WebSocket on iOS without changing store code.
public protocol WorkstreamTransport: Sendable {
    /// Subscribes to the inbound event stream. The implementation is
    /// expected to call `onEvent` on each delivered frame; the caller is
    /// responsible for dispatching to the appropriate actor before
    /// mutating shared state.
    func subscribe(onEvent: @escaping @Sendable (WorkstreamEvent) -> Void) async throws

    /// Sends a user-initiated action back through the transport. The
    /// implementation decides how to route the reply (e.g. via the
    /// request-id correlation map for blocking hooks).
    func send(_ action: WorkstreamAction) async throws
}

/// No-op transport useful for tests and the default store constructor.
public struct NullWorkstreamTransport: WorkstreamTransport {
    public init() {}

    public func subscribe(onEvent: @escaping @Sendable (WorkstreamEvent) -> Void) async throws {
        // Intentionally blank — no events are ever delivered.
    }

    public func send(_ action: WorkstreamAction) async throws {
        // Silently drop; mirrors /dev/null semantics for tests.
    }
}
