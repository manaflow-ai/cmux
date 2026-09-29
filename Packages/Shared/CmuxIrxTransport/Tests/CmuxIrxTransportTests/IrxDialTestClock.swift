import Foundation
import os

/// A virtual monotonic clock that advances to the next armed deadline on demand.
final class IrxDialTestClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant

    private struct State {
        var now = ContinuousClock.now
        var sleepers: [UUID: (Instant, CheckedContinuation<Void, any Error>)] = [:]
        var observers: [CheckedContinuation<Void, Never>] = []
    }

    // Clock requires synchronous `now`; this test-only lock also arbitrates
    // registration/cancellation so continuations are resumed exactly once.
    private let state = OSAllocatedUnfairLock(initialState: State())
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (immediate, observers) = state.withLock { value -> (
                    Result<Void, any Error>?, [CheckedContinuation<Void, Never>]
                ) in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline <= value.now { return (.success(()), []) }
                    value.sleepers[id] = (deadline, continuation)
                    let observers = value.observers
                    value.observers = []
                    return (nil, observers)
                }
                if let immediate { continuation.resume(with: immediate) }
                observers.forEach { $0.resume() }
            }
        } onCancel: {
            self.state.withLock { $0.sleepers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }

    func waitUntilArmed() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { value in
                if !value.sleepers.isEmpty { return true }
                value.observers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func advance() {
        let expired = state.withLock { value -> [CheckedContinuation<Void, any Error>] in
            guard let next = value.sleepers.values.map(\.0).min() else { return [] }
            value.now = max(value.now, next)
            let expired = value.sleepers.filter { $0.value.0 <= value.now }
            for id in expired.keys { value.sleepers[id] = nil }
            return expired.values.map(\.1)
        }
        expired.forEach { $0.resume() }
    }
}
