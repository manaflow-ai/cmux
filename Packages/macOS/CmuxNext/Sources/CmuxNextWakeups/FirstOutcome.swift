import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// One value, delivered once to each waiter: the first `resolve` wins; later ones are dropped.
/// Race an event, a one-shot DemandTimer limit and cancellation with it instead of a task group
/// whose deadline would wait for a loser (check-concurrency).
public final class FirstOutcome<Value: Sendable>: Sendable {
    private typealias Waiter = OnceContinuation<Value, OnceContinuationError>

    private enum Phase {
        case pending([Waiter])
        case done(Value)
    }
    private let phase = Mutex<Phase>(.pending([]))

    /// An outcome nothing resolved yet.
    public init() {}

    /// Delivers `value` when it is the first; any later value is dropped. Any thread.
    public func resolve(_ value: Value) {
        let waiters: [Waiter] = phase.withLock { phase in
            guard case .pending(let waiters) = phase else { return [] }
            phase = .done(value)
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    /// The first resolved value: at once when one came, else when the first comes.
    public func value() async -> Value {
        // The phase holds each waiter until resolve, so none ends abandoned while this call keeps `self`;
        // if one did, the wait starts again from the phase.
        while true {
            do {
                return try await withOnceContinuation { (continuation: Waiter) in
                    let ready: Value? = phase.withLock { phase in
                        switch phase {
                        case .done(let value): return value
                        case .pending(let waiters): phase = .pending(waiters + [continuation]); return nil
                        }
                    }
                    if let ready { continuation.resume(returning: ready) }
                }
            } catch {
                continue
            }
        }
    }
}
