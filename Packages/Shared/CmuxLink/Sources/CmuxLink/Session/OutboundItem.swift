/// One frame waiting in the session's send pump.
struct OutboundItem: Sendable {
    enum After: Sendable {
        case none
        /// The session is closing: close the transport after this frame.
        case closeTransport
    }

    var frame: LinkFrame
    var lane: TransportLane
    /// The channel whose budget counts this frame (non-reliable data only).
    var budgetChannel: UInt32?
    var bytes: Int
    var enqueuedAt: Duration
    /// Partial reliability: dropped when older than this at dequeue.
    var lifetime: Duration?
    var after: After = .none
}
