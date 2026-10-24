import Foundation

/// A clock that moves only when the test advances it (hover dwell, tooltip
/// delay and warm-group tests: a wall clock on a throttled runner stretched
/// each step of a sweep past the delays).
///
/// Superseded by CmuxNextWakeupsTestSupport's ManualClock (signal waits, no
/// poll). Only the five sidebar hover-card suites still use this copy; it is
/// deleted in the push that moves them, after their owner (a590) gives them a
/// time limit (plans/cmux-next/idle-wakeups.md section 8). New tests use the
/// shared clock, written `CmuxNextWakeupsTestSupport.ManualClock` while this
/// copy shadows the name in this module.
nonisolated final class ManualClock: Clock, @unchecked Sendable {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    nonisolated private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<Int> = []
    private var nextID = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    @concurrent func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { cancelled.insert(id); return nil }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits (bounded) until a timer is asleep on the clock. A timer reads
    /// `now` for its deadline when its task starts, off the main actor:
    /// advancing before then would push its deadline back by the advance.
    func waitForSleeper() async throws {
        for _ in 0..<20 where lock.withLock({ sleepers.isEmpty }) { await Task.yield() }
        for _ in 0..<500 where lock.withLock({ sleepers.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        // No timer asleep after the bound: advancing now would test nothing, so the test fails here.
        if lock.withLock({ sleepers.isEmpty }) { throw NoSleeper() }
    }

    /// `waitForSleeper` timed out: no timer went to sleep on the clock.
    struct NoSleeper: Error, CustomStringConvertible {
        var description: String { "no timer went to sleep on the manual clock within 2.5 s" }
    }

    /// Moves the clock on and wakes every sleeper whose deadline it reached.
    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
