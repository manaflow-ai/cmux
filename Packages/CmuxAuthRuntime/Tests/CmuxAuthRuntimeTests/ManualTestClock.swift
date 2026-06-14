import Foundation

/// A manually-advanced virtual clock for deadline tests: time only moves when
/// the test calls ``advance(by:)``, so timeout behavior is exercised without
/// real waiting. Sleeps are cancellation-responsive (resuming with
/// `CancellationError`), matching the contract `withAuthPhaseTimeout` relies on
/// to clean up the losing deadline child.
final class ManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    /// Sleeps cancelled before their continuation was parked (the
    /// `withTaskCancellationHandler` handler can run first).
    private var cancelledSleeperIDs: Set<UUID> = []
    private var parkWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentInstant
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledSleeperIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= currentInstant {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                let satisfied = takeSatisfiedParkWaitersLocked()
                lock.unlock()
                for waiter in satisfied { waiter.resume() }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil { cancelledSleeperIDs.insert(id) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `count` sleepers are parked, so a test advances
    /// time only once the deadline under test is actually waiting (instead of
    /// racing its start).
    func waitUntilSleepers(count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if sleepers.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            parkWaiters.append((count, continuation))
            lock.unlock()
        }
    }

    /// Advance virtual time, resuming every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        var due: [Sleeper] = []
        for (id, sleeper) in sleepers where sleeper.deadline <= currentInstant {
            sleepers[id] = nil
            due.append(sleeper)
        }
        lock.unlock()
        for sleeper in due.sorted(by: { $0.deadline < $1.deadline }) {
            sleeper.continuation.resume()
        }
    }

    private func takeSatisfiedParkWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        var satisfied: [CheckedContinuation<Void, Never>] = []
        parkWaiters.removeAll { waiter in
            guard sleepers.count >= waiter.count else { return false }
            satisfied.append(waiter.continuation)
            return true
        }
        return satisfied
    }
}
