import CmuxNextCompat

/// One value, delivered once to one waiter: the first `resolve` wins; later ones are dropped.
/// Race an event, a one-shot DemandTimer limit and cancellation with it instead of a task group
/// whose deadline would wait for a loser (check-concurrency).
public final class FirstOutcome<Value: Sendable>: Sendable {
    private enum Phase {
        case pending(CheckedContinuation<Value, Never>?)
        case done(Value)
    }
    private let phase = Mutex<Phase>(.pending(nil))

    public init() {}

    public func resolve(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>? = phase.withLock { phase in
            guard case .pending(let waiter) = phase else { return nil }
            phase = .done(value)
            return waiter
        }
        waiter?.resume(returning: value)
    }

    public func value() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = phase.withLock { phase in
                switch phase {
                case .done(let value): return value
                case .pending: phase = .pending(continuation); return nil
                }
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
