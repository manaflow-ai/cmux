/// A point-in-time list of navigable focus-history menu items, with the
/// total count and whether the list was truncated by a `maxItemCount`.
public struct FocusHistoryMenuSnapshot: Equatable, Sendable {
    /// The (possibly truncated) menu items.
    public let items: [FocusHistoryMenuItem]
    /// The total navigable item count before truncation.
    public let totalItemCount: Int
    /// Whether `items` was truncated to a `maxItemCount`.
    public let isLimited: Bool

    /// Creates a snapshot.
    public init(items: [FocusHistoryMenuItem], totalItemCount: Int, isLimited: Bool) {
        self.items = items
        self.totalItemCount = totalItemCount
        self.isLimited = isLimited
    }

    /// Merges a back and a forward snapshot into one recency-ordered list
    /// (most recently focused first; ties broken by the later history index),
    /// optionally truncated to `maxItemCount`.
    ///
    /// Replaces the legacy app-side `FocusHistoryMenuSnapshotBuilder`
    /// namespace enum; the merge logic is unchanged.
    public static func recentlyFocused(
        back: FocusHistoryMenuSnapshot,
        forward: FocusHistoryMenuSnapshot,
        maxItemCount: Int? = nil
    ) -> FocusHistoryMenuSnapshot {
        let items = (back.items + forward.items)
            .sorted { lhs, rhs in
                if lhs.focusedAt == rhs.focusedAt {
                    return lhs.historyIndex > rhs.historyIndex
                }
                return lhs.focusedAt > rhs.focusedAt
            }

        if let maxItemCount, maxItemCount >= 0, items.count > maxItemCount {
            return FocusHistoryMenuSnapshot(
                items: Array(items.prefix(maxItemCount)),
                totalItemCount: items.count,
                isLimited: true
            )
        }

        return FocusHistoryMenuSnapshot(
            items: items,
            totalItemCount: items.count,
            isLimited: false
        )
    }
}
