/// Lifecycle state of one nested-provider attachment.
///
/// Raw values are intended for persistence and control-socket payloads; do not rename casually.
public enum NestedConnectionState: String, Codable, Sendable, Hashable, CaseIterable {
    /// No attachment is active.
    case disconnected
    /// Connection attempt is in flight.
    case connecting
    /// Snapshot/events are flowing and mutations may be allowed.
    case live
    /// Last known topology is retained but the stream is inconsistent or down.
    case stale
    /// Handshake succeeded but protocol/capabilities are unsupported.
    case incompatible
    /// Security or policy checks rejected the endpoint.
    case rejected
}
