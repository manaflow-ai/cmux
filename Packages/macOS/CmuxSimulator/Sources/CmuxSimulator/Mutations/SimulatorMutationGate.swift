import Foundation

/// A cancellation-aware keyed advisory lock shared by host and worker processes.
///
/// Every owner opens an independent `O_CLOEXEC` descriptor. The kernel releases
/// its `flock` ownership when the process crashes, while deterministic key order
/// prevents deadlocks when one mutation spans multiple Simulator resources.
package struct SimulatorMutationGate: Sendable {
    private let lockDirectory: URL
    private let fileSystem: any SimulatorMutationLockFileSystem

    /// Creates a mutation gate with injectable lock storage.
    package init(
        lockDirectory: URL? = nil,
        fileSystem: any SimulatorMutationLockFileSystem =
            SimulatorPOSIXMutationLockFileSystem()
    ) {
        self.lockDirectory = lockDirectory ?? fileSystem.defaultLockDirectory
        self.fileSystem = fileSystem
    }

    /// Runs an operation while holding every requested key in deterministic order.
    package func withLocks<Result>(
        _ keys: [SimulatorMutationKey],
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async throws -> Result {
        _ = isolation
        let orderedKeys = Array(Set(keys)).sorted { $0.value < $1.value }
        guard !orderedKeys.isEmpty else { return try await operation() }
        try fileSystem.prepareLockDirectory(lockDirectory)

        var lockedDescriptors: [Int32] = []
        var pendingDescriptor: Int32?
        defer {
            if let pendingDescriptor { fileSystem.close(pendingDescriptor) }
            for descriptor in lockedDescriptors.reversed() {
                fileSystem.unlock(descriptor)
                fileSystem.close(descriptor)
            }
        }

        for key in orderedKeys {
            try Task.checkCancellation()
            let descriptor = try fileSystem.openLockFile(
                lockDirectory.appendingPathComponent(simulatorMutationLockFileName(for: key))
            )
            pendingDescriptor = descriptor
            let fileSystem = self.fileSystem
            try await Task.detached(priority: nil) {
                try fileSystem.lock(descriptor)
            }.value
            try Task.checkCancellation()
            lockedDescriptors.append(descriptor)
            pendingDescriptor = nil
        }
        try Task.checkCancellation()
        return try await operation()
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
