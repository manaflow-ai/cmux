import Foundation

/// Serializes camera cleanup across worker-client replacement. A replacement
/// client observes the same tail task and cannot configure injection until an
/// older client's cleanup has stopped mutating Simulator application state.
actor SimulatorCameraCleanupCoordinator {
    private struct Target: Hashable {
        let deviceIdentifier: String
        let bundleIdentifier: String
    }

    private var tail: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var ownerByTarget: [Target: UUID] = [:]
    private let ownershipStore: SimulatorCrossProcessOwnershipStore

    init(
        ownershipStore: SimulatorCrossProcessOwnershipStore =
            SimulatorCrossProcessOwnershipStore()
    ) {
        self.ownershipStore = ownershipStore
    }

    func claim(deviceIdentifier: String, bundleIdentifier: String) async throws -> UUID {
        while let pendingCleanup = tail {
            let observedRevision = revision
            await pendingCleanup.value
            if revision == observedRevision { break }
        }
        let owner = try ownershipStore.claim(
            namespace: "camera",
            components: [deviceIdentifier, bundleIdentifier]
        )
        ownerByTarget[Target(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )] = owner
        return owner
    }

    func isCurrent(
        _ owner: UUID,
        deviceIdentifier: String,
        bundleIdentifier: String
    ) -> Bool {
        ownerByTarget[Target(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )] == owner && ownershipStore.isCurrent(
            owner,
            namespace: "camera",
            components: [deviceIdentifier, bundleIdentifier]
        )
    }

    func enqueue(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        revision &+= 1
        let taskRevision = revision
        tail = task
        Task { [weak self] in
            await task.value
            await self?.clearTail(revision: taskRevision)
        }
        return task
    }

    func currentTask() -> Task<Void, Never>? {
        tail
    }

    private func clearTail(revision: UInt64) {
        guard self.revision == revision else { return }
        tail = nil
    }
}
