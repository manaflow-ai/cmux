import CmuxNextCompat
import CmuxSafeConcurrency

/// One value, delivered once: the first `resolve` wins; later ones are dropped. Every waiter, before
/// or after the resolve, gets that value.
/// Race an event, a one-shot DemandTimer limit and cancellation with it instead of a task group
/// whose deadline would wait for a loser (check-concurrency).
public final class FirstOutcome<Value: Sendable>: Sendable {
    private enum Phase {
        case pending([OnceContinuation<Value?, Never>])
        case done(Value)
    }
    private let phase = CmuxNextCompat.Mutex<Phase>(.pending([]))

    public init() {}

    public func resolve(_ value: Value) {
        let waiters: [OnceContinuation<Value?, Never>] = phase.withLock { phase in
            guard case .pending(let waiters) = phase else { return [] }
            phase = .done(value)
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    public func value() async -> Value {
        // The phase holds every waiter until the resolve, so nil (a waiter dropped unresumed, which
        // OnceContinuation reports) cannot come from here; it waits again.
        let resolved = await withOnceContinuation(ifDropped: nil) { (continuation: OnceContinuation<Value?, Never>) in
            let ready: Value? = phase.withLock { phase in
                switch phase {
                case .done(let value): return value
                case .pending(let waiters): phase = .pending(waiters + [continuation]); return nil
                }
            }
            if let ready { continuation.resume(returning: ready) }
        }
        guard let resolved else { return await value() }
        return resolved
    }
}
