public import CmuxNextSettings
import Synchronization

/// Recent `action.run` results by idempotency key (plans/cmux-next/state-ownership.md 4.4).
///
/// A retry with the key of a finished run gets that run's reply; a retry
/// while the run is still settling waits for it. A run that never started
/// (`not_run`) leaves no entry, so its retry runs. A key reused for a
/// different request is a conflict. Bounded: the oldest finished entries go
/// first; in-flight entries stay until their run settles.
public final class ControlIdempotencyCache: Sendable {
    public typealias Outcome = Result<JSONValue, ControlError>

    /// What a new run with a key should do.
    enum Claim {
        /// Run it; call ``finish(_:with:)`` or ``forget(_:)`` afterwards.
        case run
        /// It already finished with this outcome.
        case finished(Outcome)
        /// The same run is in flight: await its outcome (nil: it never ran).
        case join(Joiner)
        /// The key was used for a different request.
        case conflict
    }

    struct Joiner: Sendable {
        let cache: ControlIdempotencyCache
        let key: String

        func outcome() async -> Outcome? {
            await withCheckedContinuation { continuation in
                cache.addWaiter(continuation, key: key)
            }
        }
    }

    private struct Entry {
        var fingerprint: ControlActionRequest
        var outcome: Outcome?
        var waiters: [CheckedContinuation<Outcome?, Never>] = []
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var order: [String] = []
    }

    public let limit: Int
    private let state = Mutex(State())

    public init(limit: Int = 256) {
        self.limit = limit
    }

    func claim(_ key: String, fingerprint: ControlActionRequest) -> Claim {
        state.withLock { state in
            if let entry = state.entries[key] {
                guard entry.fingerprint == fingerprint else { return .conflict }
                if let outcome = entry.outcome { return .finished(outcome) }
                return .join(Joiner(cache: self, key: key))
            }
            state.entries[key] = Entry(fingerprint: fingerprint)
            state.order.append(key)
            // Oldest finished entry first. An in-flight entry stays until its
            // run calls `finish` or `forget`: those carry only the key, so a
            // recycled key would hand one run's outcome to another.
            while state.order.count > limit {
                guard let index = state.order.firstIndex(where: { state.entries[$0]?.outcome != nil }) else { break }
                let evicted = state.order.remove(at: index)
                state.entries.removeValue(forKey: evicted)
            }
            return .run
        }
    }

    /// Stores the outcome of a run that started and wakes its joiners.
    func finish(_ key: String, with outcome: Outcome) {
        let waiters = state.withLock { state -> [CheckedContinuation<Outcome?, Never>] in
            guard var entry = state.entries[key], entry.outcome == nil else { return [] }
            entry.outcome = outcome
            let waiters = entry.waiters
            entry.waiters = []
            state.entries[key] = entry
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// Drops the entry of a run that never started, so a retry runs.
    func forget(_ key: String) {
        let waiters = state.withLock { state -> [CheckedContinuation<Outcome?, Never>] in
            state.order.removeAll { $0 == key }
            return state.entries.removeValue(forKey: key)?.waiters ?? []
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    fileprivate func addWaiter(_ waiter: CheckedContinuation<Outcome?, Never>, key: String) {
        let ready = state.withLock { state -> Outcome?? in
            guard var entry = state.entries[key] else { return .some(nil) }
            if let outcome = entry.outcome { return .some(outcome) }
            entry.waiters.append(waiter)
            state.entries[key] = entry
            return .none
        }
        if case .some(let outcome) = ready { waiter.resume(returning: outcome) }
    }

    var count: Int { state.withLock { $0.entries.count } }
}
