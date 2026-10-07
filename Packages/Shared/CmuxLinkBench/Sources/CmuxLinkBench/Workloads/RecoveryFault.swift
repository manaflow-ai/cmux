/// The fault a recovery sample injects.
enum RecoveryFault: String, Sendable {
    /// Every live transport dies (the peer connection or socket is gone).
    case drop
    /// The network changed: live transports die or move, reconnects land on TURN.
    case roam
}
