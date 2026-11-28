public import CMUXMobileCore

/// One generation of locally observed private-network reachability.
public struct CmxIrohNetworkPathSnapshot: Equatable, Sendable {
    /// A process-monotonic generation advanced for every path change.
    public let generation: UInt64

    /// Provider-qualified profiles active in this exact generation.
    public let activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>

    /// Creates a path snapshot supplied by the platform network observer.
    public init(
        generation: UInt64,
        activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>
    ) {
        self.generation = generation
        self.activeNetworkProfiles = activeNetworkProfiles
    }
}
