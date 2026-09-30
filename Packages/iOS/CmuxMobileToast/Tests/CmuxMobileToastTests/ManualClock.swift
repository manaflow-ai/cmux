import Foundation

/// A hand-advanced `Clock` so ToastCenter dwell policy is testable without
/// wall-clock sleeps. `advance(by:)` resumes every sleeper whose deadline has
/// been reached; sleepers registering at or before the current instant resume
/// immediately; cancelled sleepers resume by throwing `CancellationError`,
/// matching `ContinuousClock` semantics.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: UnsafeContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    /// Sleep IDs whose cancellation handler ran before the continuation was
    /// registered; the registration throws instead of suspending.
    private var preCancelledIDs: Set<UUID> = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    var minimumResolution: Duration { .zero }

    /// The number of tasks currently suspended in `sleep`.
    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                lock.lock()
                if preCancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= _now {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            cancelSleeper(id: id)
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        _now = _now.advanced(by: duration)
        let due = sleepers
            .filter { $0.deadline <= _now }
            .sorted { $0.deadline < $1.deadline }
        sleepers.removeAll { $0.deadline <= _now }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(id: UUID) {
        lock.lock()
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            preCancelledIDs.insert(id)
            lock.unlock()
            return
        }
        let sleeper = sleepers.remove(at: index)
        lock.unlock()
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
