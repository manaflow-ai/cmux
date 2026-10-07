import CmuxMobileWire
import Foundation

/// Idempotency for phone ops, keyed `(install, idempotency_key)` so a resend
/// over the link `rpc` channel and over `HostDO` dedupes to one effect
/// (OWNERSHIP-PRINCIPLES invariant 5). Bounded: the oldest decided keys are
/// forgotten past `capacity`. A gap until the daemon store keys every op
/// itself (ownership.md); the daemon also gets the key as its mutation id.
public actor MobileOpLedger {
    private struct Entry {
        var fingerprint: Data
        var outcome: MobileOpOutcome?
        var task: Task<MobileOpOutcome, Never>?
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
    }

    /// Runs `body` once per key. A repeat with the same fingerprint gets the
    /// first outcome (`replayed`); a different fingerprint is `idempotency.conflict`.
    public func run(install: String, key: String, fingerprint: Data,
                    body: @escaping @Sendable () async -> MobileOpOutcome) async -> (MobileOpOutcome, replayed: Bool) {
        let id = "\(install)|\(key)"
        if let entry = entries[id] {
            guard entry.fingerprint == fingerprint else {
                return (.reject(tx: "tx_conflict", MobileOpRejection(
                    code: "idempotency.conflict", message: "idempotency key reused with other params")), false)
            }
            if let outcome = entry.outcome { return (outcome, true) }
            if let task = entry.task { return (await task.value, true) }
        }
        let task = Task { await body() }
        entries[id] = Entry(fingerprint: fingerprint, outcome: nil, task: task)
        order.append(id)
        let outcome = await task.value
        if case .reject(_, let rejection) = outcome, rejection.retryable {
            // Outcome unknown (daemon unreachable): the client resends with the
            // same key and must reach the daemon again.
            entries[id] = nil
            order.removeAll { $0 == id }
            return (outcome, false)
        }
        entries[id]?.outcome = outcome
        entries[id]?.task = nil
        while order.count > capacity {
            let oldest = order.removeFirst()
            if entries[oldest]?.task == nil { entries[oldest] = nil }
        }
        return (outcome, false)
    }

    /// Decided keys among `keys` for this install (snapshot `decided`).
    public func decided(install: String, keys: [String]) -> [DecidedKey] {
        keys.compactMap { key in
            guard let outcome = entries["\(install)|\(key)"]?.outcome else { return nil }
            return DecidedKey(idempotencyKey: key, ok: outcome.ok, sequence: outcome.sequence)
        }
    }
}
