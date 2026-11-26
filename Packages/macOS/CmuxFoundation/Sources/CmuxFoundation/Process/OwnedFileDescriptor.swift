import Darwin
import Foundation
import os

/// Idempotent owner for one close-on-exec POSIX file descriptor.
///
/// Safety: the descriptor number is immutable and its one-way open state is
/// protected by `state`, so concurrent cleanup can close it at most once.
final class OwnedFileDescriptor: @unchecked Sendable {
    let rawValue: Int32

    private let state = OSAllocatedUnfairLock(initialState: true)

    init(duplicating descriptor: Int32) throws {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        rawValue = duplicate
    }

    deinit {
        close()
    }

    func close() {
        let wasOpen = state.withLock { isOpen -> Bool in
            guard isOpen else { return false }
            isOpen = false
            return true
        }
        if wasOpen {
            _ = Darwin.close(rawValue)
        }
    }
}
