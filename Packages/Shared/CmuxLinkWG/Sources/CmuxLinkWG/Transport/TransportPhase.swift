enum TransportPhase: Equatable {
    /// WireGuard handshake not complete; not yet handed to the session.
    case handshaking
    case open
    /// Graceful close in progress: waiting for acks, then `close`/`closeAck`.
    case closing
    case closed
}
