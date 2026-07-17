import Foundation

/// A cancellation-aware keyed advisory lock shared by host and worker processes.
///
/// Every owner opens an independent `O_CLOEXEC` descriptor. The kernel releases
/// its `flock` ownership when the process crashes, while deterministic key order
/// prevents deadlocks when one mutation spans multiple Simulator resources.
package struct SimulatorMutationGate: Sendable {
    private let lockDirectory: URL
    private let fileSystem: any SimulatorMutationLockFileSystem
    private let contentionWaiter: any SimulatorMutationLockWaiting

    /// Creates a mutation gate with injectable lock storage and contention waiting.
    package init(
        lockDirectory: URL? = nil,
        fileSystem: any SimulatorMutationLockFileSystem =
            SimulatorPOSIXMutationLockFileSystem(),
        contentionWaiter: any SimulatorMutationLockWaiting =
            ContinuousSimulatorMutationLockWaiter()
    ) {
        self.lockDirectory = lockDirectory ?? fileSystem.defaultLockDirectory
        self.fileSystem = fileSystem
        self.contentionWaiter = contentionWaiter
    }

    /// Runs an operation while holding every requested key in deterministic order.
    package func withLocks<Result>(
        _ keys: [SimulatorMutationKey],
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async throws -> Result {
        _ = isolation
        let lease = try await acquireLocks(keys)
        defer { lease.release() }
        return try await operation()
    }

    /// Acquires keyed locks until the returned lease is explicitly released or deallocated.
    package func acquireLocks(
        _ keys: [SimulatorMutationKey],
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> SimulatorMutationLease {
        _ = isolation
        let scopedKeys = keys + keys.compactMap(\.deviceScope)
        let orderedKeys = Array(Set(scopedKeys)).sorted { $0.value < $1.value }
        guard !orderedKeys.isEmpty else {
            return SimulatorMutationLease(fileSystem: fileSystem, descriptors: [])
        }
        try fileSystem.prepareLockDirectory(lockDirectory)

        var lockedDescriptors: [Int32] = []
        var pendingDescriptor: Int32?
        do {
            for key in orderedKeys {
                try Task.checkCancellation()
                let descriptor = try fileSystem.openLockFile(
                    lockDirectory.appendingPathComponent(simulatorMutationLockFileName(for: key))
                )
                pendingDescriptor = descriptor
                while true {
                    try Task.checkCancellation()
                    if try fileSystem.tryLock(descriptor) { break }
                    try await contentionWaiter.wait()
                }
                try Task.checkCancellation()
                lockedDescriptors.append(descriptor)
                pendingDescriptor = nil
            }
            try Task.checkCancellation()
            return SimulatorMutationLease(
                fileSystem: fileSystem,
                descriptors: lockedDescriptors
            )
        } catch {
            if let pendingDescriptor { fileSystem.close(pendingDescriptor) }
            for descriptor in lockedDescriptors.reversed() {
                fileSystem.unlock(descriptor)
                fileSystem.close(descriptor)
            }
            throw error
        }
    }

}

/// Owns cross-process mutation locks for a caller-defined lifetime.
package final class SimulatorMutationLease: @unchecked Sendable {
    private let lock = NSLock()
    private let fileSystem: any SimulatorMutationLockFileSystem
    private var descriptors: [Int32]

    fileprivate init(
        fileSystem: any SimulatorMutationLockFileSystem,
        descriptors: [Int32]
    ) {
        self.fileSystem = fileSystem
        self.descriptors = descriptors
    }

    deinit {
        release()
    }

    /// Releases every held lock. Repeated calls are harmless.
    package func release() {
        lock.lock()
        let descriptors = self.descriptors
        self.descriptors.removeAll()
        lock.unlock()
        for descriptor in descriptors.reversed() {
            fileSystem.unlock(descriptor)
            fileSystem.close(descriptor)
        }
    }
}

private func simulatorMutationLockFileName(for key: SimulatorMutationKey) -> String {
    var first: UInt64 = 0xcbf29ce484222325
    var second: UInt64 = 0x9e3779b97f4a7c15
    for byte in key.value.utf8 {
        first ^= UInt64(byte)
        first &*= 0x100000001b3
        second ^= UInt64(byte) &+ 0x9d
        second = (second << 7) | (second >> 57)
        second &*= 0x9e3779b185ebca87
    }
    return String(format: "%016llx%016llx.lock", first, second)
}
