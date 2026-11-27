import Foundation

/// Shares per-target camera cleanup ownership between worker-client factories.
public struct SimulatorCameraCleanupOwnershipScope: Sendable {
    let ownershipStore: SimulatorCrossProcessOwnershipStore
    let coordinator: SimulatorCameraCleanupCoordinator

    /// Creates an isolated scope for an independent service graph.
    public init(fileManager: FileManager = FileManager(), makeUUID: () -> UUID = UUID.init) {
        let ownershipStore = SimulatorCrossProcessOwnershipStore(
            directory: fileManager.temporaryDirectory.appendingPathComponent(
                "com.cmux.simulator-camera-cleanup-\(makeUUID().uuidString)",
                isDirectory: true
            )
        )
        self.ownershipStore = ownershipStore
        coordinator = SimulatorCameraCleanupCoordinator(ownershipStore: ownershipStore)
    }

    /// Creates a scope backed by a caller-owned directory. App composition
    /// roots pass one stable directory to every pane and worker client.
    public init(directory: URL) {
        let ownershipStore = SimulatorCrossProcessOwnershipStore(directory: directory)
        self.ownershipStore = ownershipStore
        coordinator = SimulatorCameraCleanupCoordinator(ownershipStore: ownershipStore)
    }

    /// Waits for every cleanup already owned by this app scope, including work
    /// that outlived the pane or worker client that scheduled it. A retained
    /// failure is retried once per call so a later quit can recover a transient
    /// rollback failure without allowing concurrent camera owners.
    /// - Returns: `true` when every observed cleanup completed successfully.
    public func waitForPendingCleanup() async -> Bool {
        await coordinator.waitForPendingCleanup()
    }

    /// Cancels every app-owned camera rollback and waits only for the supplied
    /// grace period. The durable authorization record remains when a rollback
    /// cannot unwind, so a later launch or quit can retry it safely.
    public func cancelPendingCleanupAndWait(timeout: Duration) async -> Bool {
        await coordinator.cancelPendingCleanupAndWait(timeout: timeout)
    }
}
