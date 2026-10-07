/// How a connection ended, for adapters that distinguish a lost path from
/// a peer that is gone (the V2 underlay: `pathLost` vs `reset`).
enum WebRTCEndKind: Sendable, Hashable {
    case open
    case local
    /// The peer closed gracefully (`fin`).
    case remote
    /// The path died; the peer may still be there.
    case pathLost
    /// The peer said `bye`, or we told it so.
    case reset
}
