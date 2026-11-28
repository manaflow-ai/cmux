public import CMUXMobileCore

/// Assigns one process-monotonic generation to a platform path snapshot joined
/// with device-local custom private-path preferences.
public actor CmxIrohNetworkPathSnapshotComposer {
    private struct Input: Equatable {
        let platformGeneration: UInt64
        let platformProfiles: Set<CmxIrohNetworkProfileKey>
        let customGeneration: UInt64
        let customProfiles: Set<CmxIrohNetworkProfileKey>
    }

    private var generation: UInt64 = 1
    private var previousInput: Input?

    public init() {}

    public func compose(
        platform: CmxIrohNetworkPathSnapshot,
        custom: CmxIrohCustomPrivatePathSnapshot
    ) -> CmxIrohNetworkPathSnapshot {
        let input = Input(
            platformGeneration: platform.generation,
            platformProfiles: platform.activeNetworkProfiles,
            customGeneration: custom.generation,
            customProfiles: custom.activeNetworkProfiles
        )
        if let previousInput, previousInput != input {
            generation = generation == .max ? 1 : generation + 1
        }
        previousInput = input
        return CmxIrohNetworkPathSnapshot(
            generation: generation,
            activeNetworkProfiles: platform.activeNetworkProfiles.union(
                custom.activeNetworkProfiles
            )
        )
    }
}
