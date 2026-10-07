import CmuxMobileWire
import Foundation

/// Idempotency for phone ops, keyed `(install, idempotency_key)` so a resend
/// over the link `rpc` channel and over `HostDO` dedupes to one effect
/// (OWNERSHIP-PRINCIPLES invariant 5). Bounded per install: the oldest
/// decided keys of that install are forgotten past `capacityPerInstall`, so
/// one device cannot evict another's keys; in-flight entries are never
/// evicted. A gap until the daemon store keys every op itself
/// (ownership.md); the daemon also gets the key as its mutation id.
public actor MobileOpLedger {
    private struct Entry {
        var fingerprint: Data
        var outcome: MobileOpOutcome?
        var task: Task<MobileOpOutcome, Never>?
    }

    private let capacityPerInstall: Int
    private var entries: [String: [String: Entry]] = [:]
    /// Decided keys per install, oldest first.
    private var decidedOrder: [String: [String]] = [:]

    public init(capacityPerInstall: Int = 256) {
        self.capacityPerInstall = max(1, capacityPerInstall)
    }

    /// Runs `body` once per key. A repeat with the same fingerprint gets the
    /// first outcome (`replayed`); a different fingerprint is `idempotency.conflict`.
    /// A retryable reject (outcome unknown) is not remembered, so a resend
    /// reaches the daemon again.
    public func run(install: String, key: String, fingerprint: Data,
                    body: @escaping @Sendable () async -> MobileOpOutcome) async -> (MobileOpOutcome, replayed: Bool) {
        if let entry = entries[install]?[key] {
            guard entry.fingerprint == fingerprint else {
                return (.reject(tx: "tx_conflict", MobileOpRejection(
                    code: "idempotency.conflict", message: "idempotency key reused with other params")), false)
            }
            if let outcome = entry.outcome { return (outcome, true) }
            if let task = entry.task {
                let outcome = await task.value
                return (outcome, !Self.isUnknown(outcome))
            }
        }
        let task = Task { await body() }
        entries[install, default: [:]][key] = Entry(fingerprint: fingerprint, outcome: nil, task: task)
        let outcome = await task.value
        if Self.isUnknown(outcome) {
            entries[install]?[key] = nil
            return (outcome, false)
        }
        entries[install]?[key] = Entry(fingerprint: fingerprint, outcome: outcome, task: nil)
        decidedOrder[install, default: []].append(key)
        while let order = decidedOrder[install], order.count > capacityPerInstall {
            let oldest = order[0]
            decidedOrder[install]?.removeFirst()
            entries[install]?[oldest] = nil
        }
        return (outcome, false)
    }

    /// Decided keys among `keys` for this install (snapshot `decided`).
    public func decided(install: String, keys: [String]) -> [DecidedKey] {
        keys.compactMap { key in
            guard let outcome = entries[install]?[key]?.outcome else { return nil }
            return DecidedKey(idempotencyKey: key, ok: outcome.ok, sequence: outcome.sequence)
        }
    }

    private static func isUnknown(_ outcome: MobileOpOutcome) -> Bool {
        if case .reject(_, let rejection) = outcome { return rejection.retryable }
        return false
    }
}
