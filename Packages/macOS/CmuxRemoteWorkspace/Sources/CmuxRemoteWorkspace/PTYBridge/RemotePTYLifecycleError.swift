/// A stable failure raised when a logical PTY attachment generation cannot start a bridge.
public enum RemotePTYLifecycleError: Error, Sendable, Equatable {
    /// The generation was intentionally closed or already retired.
    case intentionallyClosed
    /// The generation was reused with a different remote attachment identity.
    case attachmentMismatch
    /// Every bounded registry slot is occupied by a live bridge generation.
    case capacityReached
}
