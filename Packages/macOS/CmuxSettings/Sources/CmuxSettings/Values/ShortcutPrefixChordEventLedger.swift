import Foundation

/// A bounded decision ledger that prevents one physical event being routed twice.
///
/// AppKit may offer a key to the local monitor, a window's key-equivalent path,
/// and a responder replay. Hosts record the first non-pass-through decision and
/// use ``lookup(_:)`` for later offers of the same event. The bounded FIFO keeps
/// the seam safe for synthetic events whose event number is zero without adding
/// timers or sleeps to the input path.
public struct ShortcutPrefixChordEventLedger<Decision: Sendable & Equatable>: Sendable {
    private let capacity: Int
    private var decisions: [ShortcutPrefixChordEventIdentity: Decision] = [:]
    private var order: [ShortcutPrefixChordEventIdentity] = []

    /// Creates an empty ledger.
    ///
    /// - Parameter capacity: Maximum number of event decisions retained. Values
    ///   below one are clamped to one.
    public init(capacity: Int = 64) {
        self.capacity = max(capacity, 1)
    }

    /// Returns the decision previously recorded for `identity`, if any.
    public func lookup(_ identity: ShortcutPrefixChordEventIdentity) -> Decision? {
        decisions[identity]
    }

    /// Records or replaces a decision for one event identity.
    ///
    /// Re-recording an existing identity does not consume another capacity slot;
    /// this makes a copied/replayed event idempotent while preserving FIFO order.
    public mutating func record(
        _ decision: Decision,
        for identity: ShortcutPrefixChordEventIdentity
    ) {
        if decisions[identity] == nil {
            order.append(identity)
        }
        decisions[identity] = decision
        trimIfNeeded()
    }

    /// Removes one event decision and returns it when present.
    @discardableResult
    public mutating func remove(
        _ identity: ShortcutPrefixChordEventIdentity
    ) -> Decision? {
        let removed = decisions.removeValue(forKey: identity)
        if removed != nil {
            order.removeAll { $0 == identity }
        }
        return removed
    }

    /// Clears every retained decision.
    public mutating func removeAll() {
        decisions.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    /// Number of retained event decisions, exposed for deterministic tests.
    public var count: Int { decisions.count }

    private mutating func trimIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            decisions.removeValue(forKey: oldest)
        }
    }
}
