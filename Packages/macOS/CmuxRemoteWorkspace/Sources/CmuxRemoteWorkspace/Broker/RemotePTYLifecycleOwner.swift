/// The broker-owned transport attachment for one current PTY lifecycle.
public struct RemotePTYLifecycleOwner: Sendable, Equatable {
    /// The broker transport identity that owns the lifecycle.
    public let transportKey: String
    /// The exact attachment identifier registered for the lifecycle.
    public let attachmentID: String
    /// The atomic lease guarding the final readiness mutation.
    public let commitLease: RemotePTYLifecycleCommitLease

    /// Creates a lifecycle owner snapshot.
    ///
    /// - Parameters:
    ///   - transportKey: The broker transport identity.
    ///   - attachmentID: The exact registered attachment identifier.
    ///   - commitLease: The lease guarding the final readiness mutation.
    public init(
        transportKey: String,
        attachmentID: String,
        commitLease: RemotePTYLifecycleCommitLease
    ) {
        self.transportKey = transportKey
        self.attachmentID = attachmentID
        self.commitLease = commitLease
    }

    /// Compares broker transport and attachment identity, excluding the lease.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transportKey == rhs.transportKey &&
            lhs.attachmentID == rhs.attachmentID
    }
}
