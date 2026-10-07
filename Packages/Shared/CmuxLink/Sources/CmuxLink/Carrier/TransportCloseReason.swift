/// Why a transport ended.
public enum TransportCloseReason: Sendable, Hashable {
    /// This end called `close()`.
    case local
    /// The other end closed.
    case remote
    /// The path died (roam, ICE failure, socket error).
    case pathLost(String)
}
