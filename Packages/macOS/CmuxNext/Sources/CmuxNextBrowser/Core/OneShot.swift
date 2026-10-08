import Foundation
import Synchronization

/// One value, delivered once, to one waiter that may be cancelled: the
/// wait ends with `cancelled` when its task is cancelled, so no
/// continuation outlives the work that waits on it.
public nonisolated final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
        var value: Value?
        var resolved = false
    }

    private let state = Mutex(State())

    public init() {}

    /// The resolved value, or `cancelled` once the waiting task is cancelled.
    public func wait(cancelled: Value) async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                let early = state.withLock { state -> Value? in
                    if state.resolved { return state.value }
                    state.continuation = continuation
                    return nil
                }
                if let early { continuation.resume(returning: early) }
            }
        } onCancel: {
            resolve(cancelled)
        }
    }

    /// True once a value (or the cancel value) was delivered.
    public var isResolved: Bool { state.withLock { $0.resolved } }

    /// Delivers `value`; later calls do nothing.
    public func resolve(_ value: Value) {
        let waiting = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard !state.resolved else { return nil }
            state.resolved = true
            state.value = value
            defer { state.continuation = nil }
            return state.continuation
        }
        waiting?.resume(returning: value)
    }
}
