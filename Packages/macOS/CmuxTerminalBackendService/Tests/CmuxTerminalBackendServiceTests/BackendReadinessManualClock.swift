import Foundation

/// Thread safety: `lock` protects every mutable field and every continuation collection.
final class BackendReadinessManualClock: Clock, @unchecked Sendable {
    typealias Instant = BackendReadinessManualClockInstant

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: BackendReadinessManualClockSleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var parkWaiters: [
        UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)
    ] = [:]

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentInstant
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledSleeperIDs.remove(identifier) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= currentInstant {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[identifier] = BackendReadinessManualClockSleeper(
                    deadline: deadline,
                    continuation: continuation
                )
                let waiters = takeSatisfiedParkWaitersLocked()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: identifier)
            if sleeper == nil { cancelledSleeperIDs.insert(identifier) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleepers(count: Int = 1) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if sleepers.count >= count {
                    lock.unlock()
                    continuation.resume()
                } else {
                    parkWaiters[identifier] = (count, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = parkWaiters.removeValue(forKey: identifier)
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        var due: [BackendReadinessManualClockSleeper] = []
        for (identifier, sleeper) in sleepers where sleeper.deadline <= currentInstant {
            sleepers[identifier] = nil
            due.append(sleeper)
        }
        lock.unlock()
        for sleeper in due.sorted(by: { $0.deadline < $1.deadline }) {
            sleeper.continuation.resume()
        }
    }

    private func takeSatisfiedParkWaitersLocked() -> [CheckedContinuation<Void, any Error>] {
        let identifiers = parkWaiters.compactMap { identifier, waiter in
            sleepers.count >= waiter.count ? identifier : nil
        }
        return identifiers.compactMap {
            parkWaiters.removeValue(forKey: $0)?.continuation
        }
    }
}
