import Foundation

/// iMessage connector that delegates all Messages access to the external helper.
public actor IMessageHelperConnector: InboxConnector {
    /// Default iMessage helper capabilities.
    public static let defaultCapabilities: Set<InboxConnectorCapability> = [.liveEvents, .backfill, .sendReply, .deepLink]

    /// Source service owned by the connector.
    public let source: InboxSource = .imessage
    /// Capabilities supported by the helper connector.
    public let capabilities: Set<InboxConnectorCapability> = IMessageHelperConnector.defaultCapabilities
    private let helper: any IMessageHelperClient

    /// Creates an iMessage helper connector.
    /// - Parameter helper: Helper process client.
    public init(helper: any IMessageHelperClient) {
        self.helper = helper
    }

    /// Returns helper status without reading Messages data in-process.
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
            source: .imessage,
            accountID: "local",
            displayName: "Messages",
            status: accountStatus,
            message: status.message,
            credentialState: .present,
            capabilities: capabilities,
            lastSyncAt: status.lastSyncAt
        )
    }

    /// Syncs recent iMessage helper output.
    public func sync(cursor: String?) async throws -> InboxConnectorSyncResult {
        try await helper.recent(cursor: cursor)
    }

    /// Sends a user-approved reply through the helper.
    public func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws {
        try await helper.sendApprovedReply(draft: draft, thread: thread)
    }
}
