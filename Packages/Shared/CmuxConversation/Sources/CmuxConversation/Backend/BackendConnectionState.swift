/// Whether a backend is reachable.
public enum BackendConnectionState: Hashable, Sendable {
    /// Connecting, or reconnecting after a drop.
    case connecting
    /// Connected; `capabilities` says what it supports.
    case connected(BackendCapabilities)
    /// Not reachable; `reason` is for diagnostics.
    case disconnected(reason: String)
    /// The host's backend is too old for this client; it needs an update.
    case incompatible(reason: String)
}
