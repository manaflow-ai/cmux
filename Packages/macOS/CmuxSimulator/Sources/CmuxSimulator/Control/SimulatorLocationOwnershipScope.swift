import Foundation

/// Shares per-device location ownership between control-service instances.
public struct SimulatorLocationOwnershipScope: Sendable {
    let registry: SimulatorLocationOwnershipRegistry
    let recoveryStore: SimulatorLocationRouteRecoveryStore

    /// Creates an isolated scope for an independent service graph.
    public init(fileManager: FileManager = FileManager(), makeUUID: () -> UUID = UUID.init) {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
                "com.cmux.simulator-location-\(makeUUID().uuidString)",
                isDirectory: true
            )
        registry = SimulatorLocationOwnershipRegistry(
            store: SimulatorCrossProcessOwnershipStore(directory: directory)
        )
        recoveryStore = SimulatorLocationRouteRecoveryStore(
            directory: directory.appendingPathComponent("location-routes", isDirectory: true)
        )
    }

    /// Creates a scope backed by a caller-owned directory. App composition
    /// roots pass one stable directory to every pane and worker service.
    public init(directory: URL) {
        registry = SimulatorLocationOwnershipRegistry(
            store: SimulatorCrossProcessOwnershipStore(directory: directory)
        )
        recoveryStore = SimulatorLocationRouteRecoveryStore(
            directory: directory.appendingPathComponent("location-routes", isDirectory: true)
        )
    }
}
