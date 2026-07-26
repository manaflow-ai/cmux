import Foundation

/// Shares per-device location ownership between control-service instances.
public struct SimulatorLocationOwnershipScope: Sendable {
    let registry: SimulatorLocationOwnershipRegistry

    /// Creates an isolated scope for an independent service graph.
    public init(fileManager: FileManager = FileManager(), makeUUID: () -> UUID = UUID.init) {
        registry = SimulatorLocationOwnershipRegistry(store: SimulatorCrossProcessOwnershipStore(
            directory: fileManager.temporaryDirectory.appendingPathComponent(
                "com.cmux.simulator-location-\(makeUUID().uuidString)",
                isDirectory: true
            )
        ))
    }

    /// Creates a scope backed by a caller-owned directory. App composition
    /// roots pass one stable directory to every pane and worker service.
    public init(directory: URL) {
        registry = SimulatorLocationOwnershipRegistry(store: SimulatorCrossProcessOwnershipStore(
            directory: directory
        ))
    }
}
