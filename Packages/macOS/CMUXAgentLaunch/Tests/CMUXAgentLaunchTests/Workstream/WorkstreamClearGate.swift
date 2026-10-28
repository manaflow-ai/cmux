import Dispatch
import os

/// Pauses real directory operations on the dedicated persistence I/O queue.
/// Tests await entry asynchronously and release the boundary without sharing
/// the FileManager that was transferred to the persistence actor.
final class WorkstreamClearGate: Sendable {
    private let remaining = OSAllocatedUnfairLock(initialState: 0)
    private let permits = DispatchSemaphore(value: 0)
    let entries: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (entries, continuation) = AsyncStream<Void>.makeStream()
    }

    func arm(count: Int = 1) {
        remaining.withLock { $0 = count }
    }

    func release() {
        permits.signal()
    }

    /// Called only by the synchronous filesystem override on the I/O queue.
    func pauseIfArmed() {
        let shouldPause = remaining.withLock { count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        guard shouldPause else { return }
        continuation.yield(())
        permits.wait()
    }
}
