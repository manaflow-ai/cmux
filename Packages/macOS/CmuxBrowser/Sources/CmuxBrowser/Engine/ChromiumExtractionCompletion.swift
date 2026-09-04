import os

/// Guards the synchronous compare-and-set shared by Process completion paths.
///
/// SAFETY: the unfair lock protects only one non-blocking Boolean claim. The
/// continuation is resumed after the lock is released.
final class ChromiumExtractionCompletion: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        lock.withLock { claimed in
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
