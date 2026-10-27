package import Foundation
package import CmuxNextCompat
package import class CmuxSafeConcurrency.OnceContinuation
package import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// One value, delivered once, to one waiter that may be cancelled: the
/// wait ends with `cancelled` when its task is cancelled, so no
/// continuation outlives the work that waits on it.
public nonisolated final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        package var continuation: OnceContinuation<Value, OnceContinuationError>?
        package var value: Value?
        package var resolved = false

        package init(continuation: OnceContinuation<Value, OnceContinuationError>? = nil, value: Value? = nil, resolved: Bool = false) {
            self.continuation = continuation
            self.value = value
            self.resolved = resolved
        }
    }

    private let state = Mutex(State())

    public init() {}

    /// The resolved value, or `cancelled` once the waiting task is cancelled (or the wait was dropped).
    public func wait(cancelled: Value) async -> Value {
        await withTaskCancellationHandler {
            do {
                return try await withOnceContinuation { (continuation: OnceContinuation<Value, OnceContinuationError>) in
                    let early = state.withLock { state -> Value? in
                        if state.resolved { return state.value }
                        state.continuation = continuation
                        return nil
                    }
                    if let early { continuation.resume(returning: early) }
                }
            } catch {
                return cancelled
            }
        } onCancel: {
            resolve(cancelled)
        }
    }

    /// True once a value (or the cancel value) was delivered.
    public var isResolved: Bool { state.withLock { $0.resolved } }

    /// Delivers `value`; later calls do nothing.
    public func resolve(_ value: Value) {
        let waiting = state.withLock { state -> OnceContinuation<Value, OnceContinuationError>? in
            guard !state.resolved else { return nil }
            state.resolved = true
            state.value = value
            defer { state.continuation = nil }
            return state.continuation
        }
        waiting?.resume(returning: value)
    }
}
