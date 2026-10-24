import Foundation

/// Where ``HomeClientViewCache`` hands its states: the ``HomeCache`` actor, or a test's writer
/// that controls when a write ends.
protocol HomeCacheWriting: Sendable {
    /// Writes `state` unless `writer` already wrote a newer one; true when everything it holds is
    /// on disk (or a newer state replaced it).
    func write(_ state: HomeCacheState, sequence: UInt64, writer: UUID) async -> Bool
}

extension HomeCache: HomeCacheWriting {}

extension HomeCacheWriting {
    /// ``write(_:sequence:writer:)`` from synchronous code (app quit, a zero coalescing delay):
    /// waits for the write, at most `timeout`. False when it failed or did not finish in time.
    nonisolated func writeAndWait(_ state: HomeCacheState, sequence: UInt64, writer: UUID,
                                  timeout: Duration = .seconds(2)) -> Bool {
        // concurrency-allow: applicationWillTerminate is synchronous and the last batch must be on
        // disk before the process ends: one bounded wait for the actor's write, never a lock. The
        // write runs on the cooperative pool, never on the waiting thread.
        let done = DispatchSemaphore(value: 0)
        let result = WriteResult()
        // task-owner: one write the caller waits for; ends with it
        Task.detached(priority: .userInitiated) { [self] in
            result.value = await write(state, sequence: sequence, writer: writer)
            done.signal()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        guard done.wait(timeout: .now() + seconds) == .success else { return false }
        return result.value
    }
}

/// The result of one ``HomeCacheWriting/writeAndWait(_:sequence:writer:timeout:)`` write.
// Written once by the write task before it signals the semaphore and read only after the wait
// succeeds: the semaphore orders the two accesses.
private final class WriteResult: @unchecked Sendable { // crash-allow: written once before the semaphore signals, read only after the wait succeeds
    var value = false
}
