import Foundation
import os

/// Injected monotonic clock with an admission barrier; no timing assumptions.
final class ProcessSnapshotTestClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ProcessSnapshotTestClockState())
    private let reads = AsyncStream<Int>.makeStream()

    func now() -> ContinuousClock.Instant {
        let (instant, count) = state.withLock { value in
            value.reads += 1
            return (value.instant, value.reads)
        }
        reads.continuation.yield(count)
        return instant
    }

    func advance(_ duration: Duration) {
        state.withLock { $0.instant = $0.instant.advanced(by: duration) }
    }

    func waitForRead(_ expected: Int) async {
        for await count in reads.stream where count >= expected { return }
    }
}
