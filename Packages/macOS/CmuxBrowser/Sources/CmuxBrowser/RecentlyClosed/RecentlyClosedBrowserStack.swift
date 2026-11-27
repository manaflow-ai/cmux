public import Foundation

/// Bounded LIFO stack of recently-closed browser panel snapshots.
///
/// Push appends and drops the oldest entries past `capacity`; pop returns
/// the most recent. Entries for a closing workspace are purged so a stale
/// snapshot can never restore into an unrelated workspace.
public struct RecentlyClosedBrowserStack<Snapshot: BrowserPanelRestoreSnapshot>: Sendable {
    /// The entries oldest-first (the last element is the most recent close).
    public private(set) var entries: [Snapshot] = []

    /// The maximum number of entries retained (at least 1).
    public let capacity: Int

    /// Creates an empty stack retaining at most `capacity` entries.
    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Whether the stack has no entries.
    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// When the most recent entry was closed, if any.
    public var mostRecentClosedAt: Date? {
        entries.last?.closedAt
    }

    /// Appends a snapshot, dropping the oldest entries past capacity.
    public mutating func push(_ snapshot: Snapshot) {
        entries.append(snapshot)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Removes and returns the most recent snapshot, or `nil` when empty.
    public mutating func pop() -> Snapshot? {
        entries.popLast()
    }

    /// Drops every snapshot owned by the given workspace.
    public mutating func removeSnapshots(forWorkspaceId workspaceId: UUID) {
        entries.removeAll { $0.workspaceId == workspaceId }
    }
}
