import Foundation

/// Owns cross-process mutation locks for a caller-defined lifetime.
///
/// SAFETY: `lock` serializes the synchronous explicit-release and deinit paths,
/// and descriptors are removed before any file-system callback can reenter.
package final class SimulatorMutationLease: @unchecked Sendable {
    private let lock = NSLock()
    private let fileSystem: any SimulatorMutationLockFileSystem
    private var descriptors: [Int32]

    init(
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
