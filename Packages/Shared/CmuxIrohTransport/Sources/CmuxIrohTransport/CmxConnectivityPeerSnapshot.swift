public import CMUXMobileCore

/// Immutable presentation-safe state for one peer-session owner.
public struct CmxConnectivityPeerSnapshot: Equatable, Sendable {
    /// Connection phase owned by the peer actor.
    public enum Phase: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    /// Remote device represented by this owner.
    public let peerID: CmxConnectivityPeerID

    /// Current peer connection phase.
    public let phase: Phase

    /// Monotonic generation incremented for every new dial.
    public let connectionGeneration: UInt64

    /// Monotonic state revision used to reject reordered observer delivery.
    public let stateRevision: UInt64

    /// Privacy-safe terminal failure for the most recent dial or connection.
    public let failure: DiagnosticFailureKind

    /// Whether application RPC currently owns control framing.
    public let controlLaneOwned: Bool

    /// Current control owner's local role, when the lane is owned.
    public let controlPurpose: CmxTransportSessionPurpose?

    /// Creates one peer snapshot.
    public init(
        peerID: CmxConnectivityPeerID,
        phase: Phase,
        connectionGeneration: UInt64,
        stateRevision: UInt64,
        failure: DiagnosticFailureKind,
        controlLaneOwned: Bool,
        controlPurpose: CmxTransportSessionPurpose? = nil
    ) {
        self.peerID = peerID
        self.phase = phase
        self.connectionGeneration = connectionGeneration
        self.stateRevision = stateRevision
        self.failure = failure
        self.controlLaneOwned = controlLaneOwned
        self.controlPurpose = controlPurpose
    }
}
