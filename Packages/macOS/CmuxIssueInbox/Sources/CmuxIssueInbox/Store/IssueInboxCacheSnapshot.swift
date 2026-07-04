public import Foundation

/// The disk-persisted Issue Inbox cache payload.
public struct IssueInboxCacheSnapshot: Codable, Equatable, Sendable {
    /// Cached issue rows.
    public var items: [IssueInboxItem]
    /// Last successful fetch timestamp per source ID.
    public var fetchedAt: [String: Date]
    /// Issue ID to spawned workspace ID mapping.
    public var spawnedWorkspaces: [String: UUID]

    /// Creates a cache snapshot.
    ///
    /// - Parameters:
    ///   - items: Cached issue rows.
    ///   - fetchedAt: Last successful fetch timestamp per source ID.
    ///   - spawnedWorkspaces: Issue ID to spawned workspace ID mapping.
    public init(
        items: [IssueInboxItem] = [],
        fetchedAt: [String: Date] = [:],
        spawnedWorkspaces: [String: UUID] = [:]
    ) {
        self.items = items
        self.fetchedAt = fetchedAt
        self.spawnedWorkspaces = spawnedWorkspaces
    }
}
