public import Foundation

/// One locale-independent entry in the unified History timeline.
public struct VaultHistoryEvent: Identifiable, Hashable, Codable, Sendable {
    /// Stable event identity.
    public let id: String
    /// Time at which the activity occurred.
    public let timestamp: Date
    /// Category of activity represented by this event.
    public let kind: VaultHistoryEventKind
    /// Subject title captured at event time.
    public let title: String
    /// Previous title for a workspace rename event.
    public let previousTitle: String?
    /// Number of workspaces represented by a window event.
    public let workspaceCount: Int?
    /// Identity and context of the event subject.
    public let subject: VaultHistorySubject

    /// Creates a timeline event from a complete immutable snapshot.
    ///
    /// - Parameters:
    ///   - id: Stable identity. Recorded events default to a fresh UUID string.
    ///   - timestamp: Time at which the activity occurred.
    ///   - kind: Category of activity.
    ///   - title: Subject title captured at event time.
    ///   - previousTitle: Previous title for a rename event.
    ///   - workspaceCount: Number of workspaces represented by a window event.
    ///   - subject: Identity and context of the event subject.
    public init(
        id: String = UUID().uuidString,
        timestamp: Date,
        kind: VaultHistoryEventKind,
        title: String,
        previousTitle: String? = nil,
        workspaceCount: Int? = nil,
        subject: VaultHistorySubject = VaultHistorySubject()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.previousTitle = previousTitle
        self.workspaceCount = workspaceCount
        self.subject = subject
    }

    /// Orders events newest first and uses the stable identifier as a tie-breaker.
    ///
    /// - Parameters:
    ///   - lhs: First event to compare.
    ///   - rhs: Second event to compare.
    /// - Returns: `true` when `lhs` should appear before `rhs`.
    public static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        return lhs.id > rhs.id
    }

    /// Linearly merges two newest-first snapshots while preserving their order.
    ///
    /// - Parameters:
    ///   - lhs: First snapshot, ordered by ``newestFirst(_:_:)``.
    ///   - rhs: Second snapshot, ordered by ``newestFirst(_:_:)``.
    ///   - limit: Maximum number of merged events to return.
    /// - Returns: At most `limit` events in deterministic newest-first order.
    public static func mergeNewestFirst(
        _ lhs: [Self],
        _ rhs: [Self],
        limit: Int = .max
    ) -> [Self] {
        let maximumCount = max(0, limit)
        var merged: [Self] = []
        merged.reserveCapacity(min(maximumCount, lhs.count + rhs.count))
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex

        while merged.count < maximumCount
            && (lhsIndex < lhs.endIndex || rhsIndex < rhs.endIndex) {
            if rhsIndex >= rhs.endIndex
                || (lhsIndex < lhs.endIndex && !newestFirst(rhs[rhsIndex], lhs[lhsIndex])) {
                merged.append(lhs[lhsIndex])
                lhs.formIndex(after: &lhsIndex)
            } else {
                merged.append(rhs[rhsIndex])
                rhs.formIndex(after: &rhsIndex)
            }
        }
        return merged
    }
}
