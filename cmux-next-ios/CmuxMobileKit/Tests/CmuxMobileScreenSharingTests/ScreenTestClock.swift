import Foundation

/// A clock that moves only when a test calls `advance(by:)`; a cancelled
/// sleeper throws at once and leaves `pendingSleepers`.
// crash-allow: `instant` and `sleepers` are read and written only under `lock`.
final class ScreenTestClock: Clock, @unchecked Sendable {
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

    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .zero }
    var pendingSleepers: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waits = lock.withLock {
                    if deadline <= instant || Task.isCancelled { return false }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                guard !waits else { return }
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume() }
            }
        } onCancel: {
            let cancelled = self.lock.withLock { () -> Sleeper? in
                guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return self.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
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
