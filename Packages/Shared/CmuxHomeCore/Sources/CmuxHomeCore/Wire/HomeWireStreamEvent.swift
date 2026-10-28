/// What one ``HomeWireStream`` reports to ``WireHomeSource``, in socket
/// order. Events and snapshots arrive exactly once and in seq order: the
/// stream drops repeats and turns a gap into a snapshot request.
enum HomeWireStreamEvent: Sendable {
    /// The owner said `welcome` and the subscribe went out. `user` is the
    /// principal's user; `resumed` is true when the subscribe carried
    /// `after_seq` (no snapshot follows unless the owner cannot replay).
    case welcome(user: String?, resumed: Bool)
    /// A `snapshot` frame of this stream (on join, after a gap, on request).
    case snapshot(HomeWireJSON)
    /// The next `event` frame of this stream.
    case event(HomeWireJSON)
    /// A `conversation-typing` frame.
    case typing(HomeWireJSON)
    /// The socket ended; the stream dials again after its backoff.
    case disconnected
    /// The owner refused the stream for good (not a member, no such
    /// conversation): the stream stopped.
    case refused(String)
}
