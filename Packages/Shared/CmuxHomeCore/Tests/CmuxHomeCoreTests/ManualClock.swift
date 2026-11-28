import Foundation
import os

/// A clock that moves only when a test calls `advance(by:)`. Sleepers wait
/// until the clock passes their deadline; a cancelled sleeper throws at once.
/// No wall time is involved, so timing tests cannot flake under load.
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
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var now: Instant { state.withLockUnchecked { $0.now } }
    var minimumResolution: Duration { .zero }
    /// Sleeps waiting for a later `advance`.
    var pendingSleepers: Int { state.withLockUnchecked { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLockUnchecked { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waits = state.withLockUnchecked { state -> Bool in
                    if deadline <= state.now || Task.isCancelled { return false }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                guard !waits else { return }
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLockUnchecked { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    func advance(by duration: Duration) {
        let due = state.withLockUnchecked { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}
