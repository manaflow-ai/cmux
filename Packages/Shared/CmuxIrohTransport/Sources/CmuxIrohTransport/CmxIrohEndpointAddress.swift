public import CMUXMobileCore

/// A peer EndpointID plus untrusted reachability hints supplied to Iroh.
public struct CmxIrohEndpointAddress: Equatable, Sendable {
    /// The TLS-authenticated peer identity.
    public let identity: CmxIrohPeerIdentity

    /// The bounded hints for exactly one dial attempt.
    public let pathHints: [CmxIrohPathHint]

    /// Creates a dial address for one public or private attempt.
    ///
    /// - Parameters:
    ///   - identity: The expected peer EndpointID.
    ///   - pathHints: Reachability hints that never contribute authorization.
    public init(identity: CmxIrohPeerIdentity, pathHints: [CmxIrohPathHint]) {
        self.identity = identity
        self.pathHints = pathHints
    }
}
