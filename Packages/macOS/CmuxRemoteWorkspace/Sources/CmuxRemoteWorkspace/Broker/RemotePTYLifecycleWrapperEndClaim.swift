/// The exact broker ownership retired by one persistent PTY wrapper end.
public struct RemotePTYLifecycleWrapperEndClaim: Sendable, Equatable {
    /// The persistent transport that owned the lifecycle.
    public let transportKey: String

    /// The attachment registered for the lifecycle.
    public let attachmentID: String

    /// Whether the lifecycle was current for its attachment when claimed.
    public let wasCurrent: Bool

    /// Creates a wrapper-end ownership claim.
    ///
    /// - Parameters:
    ///   - transportKey: The persistent transport that owned the lifecycle.
    ///   - attachmentID: The attachment registered for the lifecycle.
    ///   - wasCurrent: Whether it was current when claimed.
    public init(transportKey: String, attachmentID: String, wasCurrent: Bool) {
        self.transportKey = transportKey
        self.attachmentID = attachmentID
        self.wasCurrent = wasCurrent
    }
}
