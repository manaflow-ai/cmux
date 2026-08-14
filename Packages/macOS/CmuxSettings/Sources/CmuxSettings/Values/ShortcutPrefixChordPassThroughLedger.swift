import Foundation

/// A one-shot ledger for suffixes that must bypass AppKit key-equivalent routing.
///
/// The local event monitor returns an unmatched suffix so the focused terminal
/// can receive it. AppKit may then offer an equal event copy to
/// `performKeyEquivalent`; a marker lets that first later offer decline cmux
/// menus. Markers are consumed exactly once and retained in a bounded FIFO.
/// Synthetic event identities (event number zero) stay distinct by their
/// complete structural tuple, so same-timestamp events cannot evict one
/// another before AppKit has a chance to replay either one.
public struct ShortcutPrefixChordPassThroughLedger: Sendable {
    private let capacity: Int
    private var markers: Set<ShortcutPrefixChordEventIdentity> = []
    private var order: [ShortcutPrefixChordEventIdentity] = []

    /// Creates an empty pass-through ledger.
    ///
    /// - Parameter capacity: Maximum number of one-shot markers retained.
    ///   Values below one are clamped to one.
    public init(capacity: Int = 64) {
        self.capacity = max(capacity, 1)
    }

    /// Marks one event identity for a single later bypass.
    public mutating func mark(_ identity: ShortcutPrefixChordEventIdentity) {
        guard !markers.contains(identity) else { return }
        guard markers.insert(identity).inserted else { return }
        order.append(identity)
        trimIfNeeded()
    }

    /// Consumes the marker for `identity`, returning whether one was present.
    @discardableResult
    public mutating func consume(_ identity: ShortcutPrefixChordEventIdentity) -> Bool {
        if markers.remove(identity) != nil {
            order.removeAll { $0 == identity }
            return true
        }
        return false
    }

    /// Returns whether a marker is present without consuming it.
    public func contains(_ identity: ShortcutPrefixChordEventIdentity) -> Bool {
        markers.contains(identity)
    }

    /// Removes every marker.
    public mutating func removeAll() {
        markers.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    /// Number of retained markers, exposed for deterministic behavior tests.
    public var count: Int { markers.count }

    private mutating func trimIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            markers.remove(oldest)
        }
    }
}
