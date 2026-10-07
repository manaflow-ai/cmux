/// Why a datagram channel ended (b3-webrtc-wg.md `UnderlayCloseReason`).
public enum WebRTCDatagramCloseReason: Sendable, Hashable {
    /// This end called `close()`.
    case local
    /// The path died (ICE failed, the peer connection dropped); the peer
    /// may still be there.
    case pathLost(String)
    /// The peer is gone: it said `bye` or closed on purpose.
    case reset
}
