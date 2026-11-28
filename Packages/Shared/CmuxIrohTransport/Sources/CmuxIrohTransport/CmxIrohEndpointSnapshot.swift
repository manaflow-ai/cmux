public import CMUXMobileCore

/// A non-sensitive snapshot of the endpoint supervisor state.
public struct CmxIrohEndpointSnapshot: Equatable, Sendable {
    /// The endpoint-instance generation, incremented for every bind attempt.
    public let runtimeGeneration: UInt64

    /// The current lifecycle state.
    public let state: CmxIrohEndpointLifecycleState

    /// The stable identity when an endpoint is active.
    public let identity: CmxIrohPeerIdentity?

    /// Creates a supervisor snapshot.
    ///
    /// - Parameters:
    ///   - runtimeGeneration: The endpoint-instance generation.
    ///   - state: The current lifecycle state.
    ///   - identity: The active stable EndpointID, if available.
    public init(
        runtimeGeneration: UInt64,
        state: CmxIrohEndpointLifecycleState,
        identity: CmxIrohPeerIdentity?
    ) {
        self.runtimeGeneration = runtimeGeneration
        self.state = state
        self.identity = identity
    }
}
