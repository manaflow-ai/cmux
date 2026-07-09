/// The shell store's seam onto the presence subscribe stream, so the live
/// wiring (``MobileShellComposite``) is testable with a scripted fake while
/// ``PresenceClient`` provides the real WebSocket transport.
public protocol PresenceSubscribing: Sendable {
    /// Open one subscribe stream: a ``PresenceUpdate/snapshot(_:)`` first,
    /// then transition events. The stream finishes when the server closes it
    /// (e.g. the token-expiry deadline) and throws on transport or decode
    /// errors; the consumer owns reconnect policy.
    func subscribe() async throws -> AsyncThrowingStream<PresenceUpdate, any Error>
}

extension PresenceClient: PresenceSubscribing {}
