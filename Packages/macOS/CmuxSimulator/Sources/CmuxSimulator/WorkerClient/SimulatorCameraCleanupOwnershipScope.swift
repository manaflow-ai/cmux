import Foundation

/// Shares per-target camera cleanup ownership between worker-client factories.
public struct SimulatorCameraCleanupOwnershipScope: Sendable {
    let coordinator: SimulatorCameraCleanupCoordinator

    /// Creates an isolated scope for an independent service graph.
    public init(fileManager: FileManager = FileManager(), makeUUID: () -> UUID = UUID.init) {
        coordinator = SimulatorCameraCleanupCoordinator(
            ownershipStore: SimulatorCrossProcessOwnershipStore(
                directory: fileManager.temporaryDirectory.appendingPathComponent(
                    "com.cmux.simulator-camera-cleanup-\(makeUUID().uuidString)",
                    isDirectory: true
                )
            )
        )
    }

    /// Creates a scope backed by a caller-owned directory. App composition
    /// roots pass one stable directory to every pane and worker client.
    public init(directory: URL) {
        coordinator = SimulatorCameraCleanupCoordinator(
            ownershipStore: SimulatorCrossProcessOwnershipStore(directory: directory)
        )
    }
}
