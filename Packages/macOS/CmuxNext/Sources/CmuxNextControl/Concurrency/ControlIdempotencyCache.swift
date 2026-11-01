public import CmuxNextSettings
import CmuxNextCompat

/// Recent `action.run` and `action.batch` results by idempotency key (plans/cmux-next/state-ownership.md 4.4).
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

    /// What a key was first used for: a retry must send the same thing.
    enum Fingerprint: Hashable, Sendable {
        /// One `action.run` request.
        case run(ControlActionRequest)
        /// One `action.batch` request: its ops in order.
        case batch([ControlActionRequest])
        /// A browser-page tab request before topology determines its action target.
        case page(method: String, params: [String: JSONValue], callerApp: String?)
    }

    private struct Entry {
        var fingerprint: Fingerprint
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

    func claim(_ key: String, fingerprint: Fingerprint) -> Claim {
        state.withLock { state in
            if let entry = state.entries[key] {
                guard entry.fingerprint == fingerprint else { return .conflict }
                if let outcome = entry.outcome { return .finished(outcome) }
                return .join(Joiner(cache: self, key: key))
            }
            state.entries.updateValue(Entry(fingerprint: fingerprint), forKey: key)
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
            state.entries.updateValue(entry, forKey: key)
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
            state.entries.updateValue(entry, forKey: key)
            return .none
        }
        if case .some(let outcome) = ready { waiter.resume(returning: outcome) }
    }

    var count: Int { state.withLock { $0.entries.count } }

    /// Whether the run under `key` recorded its outcome (a retry then replays it at once).
    func hasOutcome(_ key: String) -> Bool { state.withLock { $0.entries[key]?.outcome != nil } }
}
