import Darwin

/// Single-owner lifecycle token. Its atomic state makes the active-to-reaper
/// transfer idempotent without serializing process I/O or `waitpid`.
final class GitProcessLifecyclePermit: @unchecked Sendable {
    // Safety: this integer is accessed only through OSAtomic compare-and-swap;
    // 0 is active, 1 is reaping, and 2 is finished.
    private nonisolated(unsafe) var state: Int32 = 0

    func transferToReaper() -> Bool {
        OSAtomicCompareAndSwap32Barrier(0, 1, &state)
    }

    func finishActive() -> Bool {
        OSAtomicCompareAndSwap32Barrier(0, 2, &state)
    }

    func finishReaping() -> Bool {
        OSAtomicCompareAndSwap32Barrier(1, 2, &state)
    }
}
