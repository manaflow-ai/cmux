/// The broker-owned transport attachment for one current PTY lifecycle.
public struct ControlRemotePTYLifecycleOwner: Sendable, Equatable {
    /// The broker transport identity that owns the lifecycle.
    public let transportKey: String
    /// The exact attachment identifier registered for the lifecycle.
    public let attachmentID: String

    /// Creates a lifecycle owner snapshot.
    ///
    /// - Parameters:
    ///   - transportKey: The broker transport identity.
    ///   - attachmentID: The exact registered attachment identifier.
    public init(transportKey: String, attachmentID: String) {
        self.transportKey = transportKey
        self.attachmentID = attachmentID
    }
}
