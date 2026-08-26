/// The broker ownership that a persistent PTY wrapper-end callback must match.
public struct RemotePTYLifecycleWrapperEndOwner: Sendable, Equatable {
    /// The persistent transport that owns the lifecycle.
    public let transportKey: String

    /// The attachment registered for the lifecycle.
    public let attachmentID: String

    /// Creates a wrapper-end owner.
    ///
    /// - Parameters:
    ///   - transportKey: The persistent transport that owns the lifecycle.
    ///   - attachmentID: The attachment registered for the lifecycle.
    public init(transportKey: String, attachmentID: String) {
        self.transportKey = transportKey
        self.attachmentID = attachmentID
    }
}
