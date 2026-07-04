public import Foundation

/// macOS Notification Center connector: surfaces every app's delivered
/// notifications through the external `cmux-notif` helper, which reads the
/// system notification store locally. One Full Disk Access grant turns every
/// Mac app into an inbox source with zero per-app credentials.
public actor NotificationCenterConnector: InboxConnector {
    /// Notifications are read-only records; there is nothing to reply to.
    public static let defaultCapabilities: Set<InboxConnectorCapability> = [.backfill, .deepLink]

    /// Source service owned by the connector.
    public let source: InboxSource = .notifications
    /// Capabilities supported by the helper connector.
    public let capabilities: Set<InboxConnectorCapability> = NotificationCenterConnector.defaultCapabilities
    private let helper: any IMessageHelperClient

    /// Creates a Notification Center connector.
    /// - Parameter helper: Helper process client bound to the `cmux-notif` binary.
    public init(helper: any IMessageHelperClient) {
        self.helper = helper
    }

    /// Returns helper status without reading notification data in-process.
    public func status() async -> InboxConnectorStatus {
        let status = await helper.status()
        let accountStatus: InboxAccountStatus
        if status.ok {
            accountStatus = .connected
        } else if status.permissionDenied {
            accountStatus = .permissionDenied
        } else if !status.helperInstalled {
            accountStatus = .missingHelper
        } else {
            accountStatus = .error
        }
        return InboxConnectorStatus(
            source: .notifications,
            accountID: "local",
            displayName: "App Notifications",
            status: accountStatus,
            message: status.message,
            credentialState: .present,
            capabilities: capabilities,
            lastSyncAt: status.lastSyncAt
        )
    }

    /// Syncs recently delivered notifications from the helper.
    public func sync(cursor: String?) async throws -> InboxConnectorSyncResult {
        var result = try await helper.recent(cursor: cursor)
        // The shared helper JSON adapter emits .imessage records; rebrand the
        // payload for this source so identities and filters stay correct.
        result = InboxConnectorSyncResult(
            accounts: result.accounts.map { Self.rebranded($0) },
            threads: result.threads.map { Self.rebranded($0) },
            items: result.items.map { Self.rebranded($0) },
            nextCursor: result.nextCursor,
            status: InboxConnectorStatus(
                source: .notifications,
                accountID: result.status.accountID,
                displayName: "App Notifications",
                status: result.status.status,
                message: result.status.message,
                credentialState: result.status.credentialState,
                capabilities: capabilities,
                lastSyncAt: result.status.lastSyncAt
            )
        )
        return result
    }

    private static func rebranded(_ account: InboxAccount) -> InboxAccount {
        InboxAccount(
            source: .notifications,
            accountID: account.accountID,
            displayName: "App Notifications",
            status: account.status,
            statusMessage: account.statusMessage,
            lastSyncAt: account.lastSyncAt,
            capabilities: defaultCapabilities,
            notificationsEnabled: account.notificationsEnabled
        )
    }

    private static func rebranded(_ thread: InboxThread) -> InboxThread {
        let identity = InboxIdentity()
        return InboxThread(
            threadID: identity.threadID(source: .notifications, accountID: thread.accountID, externalThreadID: thread.externalThreadID),
            source: .notifications,
            accountID: thread.accountID,
            externalThreadID: thread.externalThreadID,
            participants: thread.participants,
            title: thread.title,
            unreadCount: thread.unreadCount,
            lastActivityAt: thread.lastActivityAt,
            isMuted: thread.isMuted,
            isPinned: thread.isPinned,
            isArchived: thread.isArchived,
            externalURL: thread.externalURL,
            metadata: thread.metadata
        )
    }

    private static func rebranded(_ item: InboxItem) -> InboxItem {
        let identity = InboxIdentity()
        return InboxItem(
            itemID: identity.itemID(source: .notifications, accountID: item.accountID, externalMessageID: item.externalMessageID),
            threadID: identity.threadID(source: .notifications, accountID: item.accountID, externalThreadID: item.metadata["chat_id"] ?? item.threadID),
            source: .notifications,
            accountID: item.accountID,
            externalMessageID: item.externalMessageID,
            sender: item.sender,
            timestamp: item.timestamp,
            bodyPreview: item.bodyPreview,
            body: item.body,
            metadata: item.metadata,
            isUnread: item.isUnread,
            isActionable: item.isActionable,
            draftID: item.draftID,
            externalURL: item.externalURL
        )
    }
}
