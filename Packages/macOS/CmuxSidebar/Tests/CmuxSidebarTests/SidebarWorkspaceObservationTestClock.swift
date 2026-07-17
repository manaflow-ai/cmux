import Foundation
import os

/// Manually advanced, cancellation-responsive clock for batch cadence tests.
///
/// `Clock.now` and cancellation handlers are synchronous protocol surfaces, so
/// this test-only clock uses one unfair lock to serialize virtual time and its
/// parked continuations; production batching state remains actor-isolated.
final class SidebarWorkspaceObservationTestClock: Clock, Sendable {
    typealias Instant = SidebarWorkspaceObservationTestInstant

    private let state = OSAllocatedUnfairLock(initialState: (
        now: Instant(offset: .zero),
        sleepers: [UUID: (
            deadline: Instant,
            continuation: CheckedContinuation<Void, any Error>
        )](),
        cancelledSleeperIds: Set<UUID>(),
        parkWaiters: [(
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )]()
    ))

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (action, satisfiedWaiters) = state.withLock { state in
                    let action: Int
                    if state.cancelledSleeperIds.remove(id) != nil {
                        action = 1
                    } else if deadline <= state.now {
                        action = 2
                    } else {
                        state.sleepers[id] = (deadline, continuation)
                        action = 0
                    }

                    var satisfied: [CheckedContinuation<Void, Never>] = []
                    state.parkWaiters.removeAll { waiter in
                        guard state.sleepers.count >= waiter.count else { return false }
                        satisfied.append(waiter.continuation)
                        return true
                    }
                    return (action, satisfied)
                }

                for waiter in satisfiedWaiters {
                    waiter.resume()
                }
                switch action {
                case 1:
                    continuation.resume(throwing: CancellationError())
                case 2:
                    continuation.resume()
                default:
                    break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelledSleeperIds.insert(id)
                    return nil
                }
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleepers(count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.sleepers.count < count else { return true }
                state.parkWaiters.append((count, continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func advance(by duration: Duration) {
        let dueContinuations = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            var due: [CheckedContinuation<Void, any Error>] = []
            for id in Array(state.sleepers.keys) {
                guard let sleeper = state.sleepers[id], sleeper.deadline <= state.now else {
                    continue
                }
                state.sleepers[id] = nil
                due.append(sleeper.continuation)
            }
            return due
        }
        for continuation in dueContinuations {
            continuation.resume()
        }
    }

    func sleeperCount() -> Int {
        state.withLock { $0.sleepers.count }
    }
}
