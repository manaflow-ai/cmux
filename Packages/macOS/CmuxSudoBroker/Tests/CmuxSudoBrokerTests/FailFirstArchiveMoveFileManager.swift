import Foundation
import os

// FileManager's inherited Sendable contract is preserved by protecting the
// one-shot synchronous fault injection with an atomic compare-and-set.
final class FailFirstArchiveMoveFileManager: FileManager, @unchecked Sendable {
    private let hasFailed = OSAllocatedUnfairLock(initialState: false)

    override func moveItem(at source: URL, to destination: URL) throws {
        let shouldFail = hasFailed.withLock { failed in
            guard !failed else { return false }
            failed = true
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: source, to: destination)
    }
}
