import Foundation

/// Result of one connector sync pass.
public struct InboxConnectorSyncResult: Sendable, Equatable {
    /// Accounts to upsert.
    public var accounts: [InboxAccount]
    /// Threads to upsert.
    public var threads: [InboxThread]
    /// Items to upsert.
    public var items: [InboxItem]
    /// Optional next sync cursor.
    public var nextCursor: String?
    /// Status after the sync attempt.
    public var status: InboxConnectorStatus

    /// Creates a sync result.
    public init(
        accounts: [InboxAccount] = [],
        threads: [InboxThread] = [],
        items: [InboxItem] = [],
        nextCursor: String? = nil,
        status: InboxConnectorStatus
    ) {
        self.accounts = accounts
        self.threads = threads
        self.items = items
        self.nextCursor = nextCursor
        self.status = status
    }
}
