/// The broker-owned transport attachment for one current PTY lifecycle.
public struct ControlRemotePTYLifecycleOwner: Sendable, Equatable {
    /// The broker transport identity that owns the lifecycle.
    public let transportKey: String
    /// The exact attachment identifier registered for the lifecycle.
    public let attachmentID: String
    /// The opaque lease guarding the final readiness mutation.
    public let commitLease: any ControlRemotePTYLifecycleCommitLease

    /// Creates a lifecycle owner snapshot.
    ///
    /// - Parameters:
    ///   - transportKey: The broker transport identity.
    ///   - attachmentID: The exact registered attachment identifier.
    ///   - commitLease: The opaque lease guarding the readiness commit.
    public init(
        transportKey: String,
        attachmentID: String,
        commitLease: any ControlRemotePTYLifecycleCommitLease
    ) {
        self.transportKey = transportKey
        self.attachmentID = attachmentID
        self.commitLease = commitLease
    }

    /// Compares only broker ownership identity; the lease is its capability.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transportKey == rhs.transportKey &&
            lhs.attachmentID == rhs.attachmentID
    }
}
