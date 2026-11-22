import Foundation
import Synchronization

/// A clock that moves only when a test calls ``advance(by:)``. Sleepers wait
/// until the clock passes their deadline; ``sleepers(atLeast:)`` waits, on a
/// signal, until code under test has started that many sleeps. No wall time
/// is involved, so timing tests cannot flake under load.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready: [CheckedContinuation<Void, Never>]? = state.withLock { state in
                    if deadline <= state.now || Task.isCancelled { return nil }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    let count = state.sleepers.count
                    let ready = state.waiters.filter { $0.count <= count }.map(\.continuation)
                    state.waiters.removeAll { $0.count <= count }
                    return ready
                }
                guard let ready else {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume() }
                    return
                }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    /// Returns once at least `count` sleeps are pending.
    func sleepers(atLeast count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
