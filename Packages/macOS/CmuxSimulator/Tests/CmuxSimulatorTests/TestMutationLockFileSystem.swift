import Foundation
@testable import CmuxSimulator

/// Test observation is synchronized by `NSCondition`; POSIX calls remain in the base value.
final class TestMutationLockFileSystem: SimulatorMutationLockFileSystem, @unchecked Sendable {
    private let base = SimulatorPOSIXMutationLockFileSystem()
    private let condition = NSCondition()
    private var attemptCount = 0

    var defaultLockDirectory: URL { base.defaultLockDirectory }

    func prepareLockDirectory(_ directory: URL) throws {
        try base.prepareLockDirectory(directory)
    }

    func openLockFile(_ url: URL) throws -> Int32 {
        try base.openLockFile(url)
    }

    func tryLock(_ descriptor: Int32) throws -> Bool {
        condition.lock()
        attemptCount += 1
        condition.broadcast()
        condition.unlock()
        return try base.tryLock(descriptor)
    }

    func unlock(_ descriptor: Int32) {
        base.unlock(descriptor)
    }

    func close(_ descriptor: Int32) {
        base.close(descriptor)
    }

    func waitUntilAttemptCount(_ expectedCount: Int) async {
        await Task.detached { [self] in
            blockUntilAttemptCount(expectedCount)
        }.value
    }

    private func blockUntilAttemptCount(_ expectedCount: Int) {
        condition.lock()
        while attemptCount < expectedCount { condition.wait() }
        condition.unlock()
    }
}
