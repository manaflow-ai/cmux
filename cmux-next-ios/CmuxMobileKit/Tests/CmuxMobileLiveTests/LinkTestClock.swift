import Foundation

/// A clock for lifecycle tests. Startup scheduling can take as long as the
/// simulator needs; heartbeat time moves only when the test advances it.
final class LinkTestClock: Clock, @unchecked Sendable {
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
    private var stopped = false
    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .zero }
    func isSleeping(until deadline: Instant) -> Bool {
        lock.withLock { sleepers.contains { $0.deadline == deadline } }
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waits = lock.withLock {
                    if stopped || deadline <= instant || Task.isCancelled { return false }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                if !waits {
                    if Task.isCancelled || lock.withLock({ stopped }) { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume() }
                }
            }
        } onCancel: {
            let cancelled = self.lock.withLock { () -> Sleeper? in
                guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return self.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Every test stops its controller first, then releases any remaining
    /// timeout race sleepers. Late registrations fail instead of leaking.
    func stop() {
        let pending = lock.withLock {
            stopped = true
            let pending = sleepers
            sleepers.removeAll()
            return pending
        }
        pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            instant = instant.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= instant }
            sleepers.removeAll { $0.deadline <= instant }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}
