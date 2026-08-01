public import CMUXMobileCore

/// Immutable process-wide connectivity state observed by Mac and iOS UI.
public struct CmxConnectivityEngineSnapshot: Equatable, Sendable {
    /// Endpoint lifecycle owned by the connectivity engine.
    public enum Phase: Equatable, Sendable {
        case stopped
        case starting
        case active
        case stopping
        case failed
    }

    /// Current engine lifecycle.
    public let phase: Phase

    /// Active endpoint generation, when bound.
    public let endpointGeneration: UInt64?

    /// Stable local endpoint identity, when bound.
    public let localIdentity: CmxIrohPeerIdentity?

    /// Last completely installed authoritative route revision.
    public let routeRevision: UInt64?

    /// One immutable state record per known peer.
    public let peers: [CmxConnectivityPeerSnapshot]

    /// Creates a process-wide snapshot.
    public init(
        phase: Phase,
        endpointGeneration: UInt64?,
        localIdentity: CmxIrohPeerIdentity?,
        routeRevision: UInt64?,
        peers: [CmxConnectivityPeerSnapshot]
    ) {
        self.phase = phase
        self.endpointGeneration = endpointGeneration
        self.localIdentity = localIdentity
        self.routeRevision = routeRevision
        self.peers = peers
    }
}
