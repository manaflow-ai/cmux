public import CmuxNextCompat
public import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Recent `action.run` and `action.batch` results by idempotency key (plans/cmux-next/state-ownership.md 4.4).
///
/// A retry with the key of a finished run gets that run's reply; a retry
/// while the run is still settling waits for it. A run that never started
/// (`not_run`) leaves no entry, so its retry runs. A key reused for a
/// different request is a conflict. Bounded: the oldest finished entries go
/// first; in-flight entries stay until their run settles.
///
/// A memory consumer off the main actor (`control-idempotency`, through
/// `AsyncMemoryConsumerRegistration`): the coordinator's limit scales ``limit``, and a release drops
/// the oldest finished entries down to it, as eviction does. The newest ``workingSet`` entries stay
/// at any limit (a retry comes right after its timeout), so a limit of 0 never makes a prompt
/// retry run its action twice. Lossy, so only critical pressure and Memory Saver shrink it.
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

        /// A joiner whose waiter is dropped unresumed answers nil, as a run that never started does: the retry runs.
        func outcome() async -> Outcome? {
            try? await withOnceContinuation { (continuation: OnceContinuation<Outcome?, OnceContinuationError>) in
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
    }

    private struct Entry {
        var fingerprint: Fingerprint
        var outcome: Outcome?
        var waiters: [OnceContinuation<Outcome?, OnceContinuationError>] = []
        /// The reply's estimated compact JSON bytes (``estimatedBytes(of:)``), counted once in ``finish(_:with:)``.
        var bytes = 0
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var order: [String] = []
        /// Entries kept at the coordinator's current limit: ``limit`` at 100 %.
        var kept: Int
        /// The sum of the entries' ``Entry/bytes``, so the memory report reads a counter, not the replies.
        var bytes = 0
    }

    /// Entries kept at the full memory limit.
    public let limit: Int
    /// Entries kept at any memory limit: the newest runs, whose retries may still come.
    static let workingSet = 16
    private let state: Mutex<State>

    public init(limit: Int = 256) {
        self.limit = limit
        state = Mutex(State(kept: limit))
    }

    /// The entries kept at `memoryLimit`: ``limit`` scaled, never below the working set.
    private func keptEntries(at memoryLimit: MemoryLimit) -> Int {
        max(memoryLimit.scale(limit), min(Self.workingSet, limit))
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
            let kept = state.kept
            Self.evictFinished(&state, downTo: kept)
            return .run
        }
    }

    /// Drops the oldest finished entries until at most `kept` entries remain or only in-flight ones do.
    private static func evictFinished(_ state: inout State, downTo kept: Int) {
        while state.order.count > kept {
            guard let index = state.order.firstIndex(where: { state.entries[$0]?.outcome != nil }) else { break }
            let evicted = state.order.remove(at: index)
            state.bytes -= state.entries.removeValue(forKey: evicted)?.bytes ?? 0
        }
    }

    /// Stores the outcome of a run that started and wakes its joiners.
    func finish(_ key: String, with outcome: Outcome) {
        let bytes = if case .success(let reply) = outcome { Self.estimatedBytes(of: reply) } else { 0 }
        let waiters = state.withLock { state -> [OnceContinuation<Outcome?, OnceContinuationError>] in
            guard var entry = state.entries[key], entry.outcome == nil else { return [] }
            entry.outcome = outcome
            entry.bytes = bytes
            state.bytes += bytes
            let waiters = entry.waiters
            entry.waiters = []
            state.entries.updateValue(entry, forKey: key)
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// Drops the entry of a run that never started, so a retry runs.
    func forget(_ key: String) {
        let waiters = state.withLock { state -> [OnceContinuation<Outcome?, OnceContinuationError>] in
            state.order.removeAll { $0 == key }
            guard let entry = state.entries.removeValue(forKey: key) else { return [] }
            state.bytes -= entry.bytes
            return entry.waiters
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    fileprivate func addWaiter(_ waiter: OnceContinuation<Outcome?, OnceContinuationError>, key: String) {
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

extension ControlIdempotencyCache: AsyncMemoryConsumer {
    /// Small replies of recent runs; a dropped one makes its retry run again.
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .small, dataAccess: .none, retention: .lossy, recreateCost: .notApplicable,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    public func updateMemoryLimit(_ limit: MemoryLimit) async -> MemoryUsage? {
        let kept = keptEntries(at: limit)
        return state.withLock { state in
            state.kept = kept
            return Self.usage(of: state)
        }
    }

    public func releaseMemory(downTo limit: MemoryLimit) async -> MemoryUsage? {
        let kept = keptEntries(at: limit)
        return state.withLock { state in
            Self.evictFinished(&state, downTo: kept)
            return Self.usage(of: state)
        }
    }

    /// The entries and their replies' bytes, from the counters the cache keeps: O(1) under the lock.
    private static func usage(of state: State) -> MemoryUsage {
        MemoryUsage(footprintBytes: state.bytes, entries: state.entries.count)
    }

    /// About how many bytes `value`'s compact JSON takes, without writing it: string and key bytes
    /// (escapes not counted), 8 per number and the punctuation. Run once per finished reply, outside
    /// the lock.
    static func estimatedBytes(of value: JSONValue) -> Int {
        switch value {
        case .null: 4
        case .bool(let flag): flag ? 4 : 5
        case .number: 8
        case .string(let text): text.utf8.count + 2
        case .array(let items): items.reduce(1 + max(items.count, 1)) { $0 + estimatedBytes(of: $1) }
        case .object(let members):
            members.reduce(1 + max(members.count, 1)) { $0 + $1.key.utf8.count + 3 + estimatedBytes(of: $1.value) }
        }
    }
}
