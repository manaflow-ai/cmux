import Foundation

/// A clock that moves only when a test advances it. `untilSleeping` waits for
/// the next sleep to begin (an event, not a time window).
final class StepClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let lock = NSLock()
    private var instant = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (due, woken) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if deadline <= instant { return (true, []) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    defer { watchers = [] }
                    return (false, watchers)
                }
                if due { continuation.resume() }
                woken.forEach { $0.resume() }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Returns once some sleep is waiting on this clock.
    func untilSleeping() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if !sleepers.isEmpty { return true }
                watchers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Moves time forward and wakes every sleep that is now due.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            instant = instant.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= instant }
            sleepers.removeAll { $0.deadline <= instant }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// Holds the completion a Photos-style load hands to its operation.
final class Finisher: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Int?, Error>) -> Void)?
    func set(_ completion: @escaping @Sendable (Result<Int?, Error>) -> Void) { lock.withLock { self.completion = completion } }
    func finish(_ result: Result<Int?, Error>) { lock.withLock { completion }?(result) }
}
