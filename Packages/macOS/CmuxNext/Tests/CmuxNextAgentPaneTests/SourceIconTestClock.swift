import CmuxNextCompat
import Foundation

/// Virtual time and event-driven deadlines; synchronous Clock reads require a short test-only lock.
nonisolated final class SourceIconTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }
    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: (Instant, CheckedContinuation<Void, any Error>)] = [:]
        var cancelled: Set<UUID> = []
    }
    private let state = Mutex(State())
    let sleeps: AsyncStream<Duration>
    private let events: AsyncStream<Duration>.Continuation

    init() {
        (sleeps, events) = AsyncStream<Duration>.makeStream(bufferingPolicy: .bufferingNewest(32))
    }
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock {
                    if $0.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= $0.now { return .success(()) }
                    $0.sleepers[id] = (deadline, continuation)
                    return nil
                }
                events.yield(deadline.offset)
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let pending = self.state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper.1 }
                state.cancelled.insert(id)
                return nil
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.value.0 <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.1)
        }
        for continuation in due { continuation.resume() }
    }
}
