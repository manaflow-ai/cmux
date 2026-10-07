/// Why an underlay ended.
public enum UnderlayCloseReason: Sendable, Hashable {
    /// This end called `close()`.
    case local
    /// The path died but the peer may still be there (ICE failed, the peer
    /// connection dropped): the transport may open a new underlay and keep
    /// its WireGuard session.
    case pathLost(String)
    /// The peer is gone (it closed the peer connection or said `bye`): the
    /// transport ends.
    case reset
}
