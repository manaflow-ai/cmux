/// The liveness classification of an existing Unix-domain socket path.
///
/// Produced by ``SocketTransport/pathProbeResult(at:)`` via a non-blocking
/// `connect(2)`. The bind-preparation flow uses it to decide whether an existing
/// socket file may be unlinked and rebound.
public enum SocketPathProbeResult: Equatable, Sendable {
    /// A listener accepted the probe connection; the socket is live.
    case connected
    /// The path is a socket file but the connection was refused (no listener).
    case refused
    /// The probe could not determine liveness; treat the path as occupied so a
    /// potentially live listener is never unlinked.
    case occupiedOrIndeterminate
    /// The path no longer exists; safe to bind.
    case stale
}
