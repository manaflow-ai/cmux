import Foundation

/// One locale-independent section produced by ``VaultHistoryGrouper``.
public struct VaultHistoryGroup: Identifiable, Equatable, Sendable {
    /// Grouping dimension that produced this section.
    public let key: VaultHistoryGroupKey
    /// Concrete subject identity represented by this section.
    public let identity: VaultHistoryGroupIdentity
    /// Events in deterministic newest-first order.
    public let events: [VaultHistoryEvent]

    /// Stable string identity derived from ``identity``.
    public var id: String { identity.id }

    /// Creates a grouped section from a grouping key, identity, and ordered events.
    ///
    /// - Parameters:
    ///   - key: Grouping dimension that produced the section.
    ///   - identity: Concrete identity represented by the section.
    ///   - events: Events in deterministic newest-first order.
    public init(
        key: VaultHistoryGroupKey,
        identity: VaultHistoryGroupIdentity,
        events: [VaultHistoryEvent]
    ) {
        self.key = key
        self.identity = identity
        self.events = events
    }
}
