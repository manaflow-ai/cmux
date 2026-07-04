import Foundation

/// Generic connector for local scripts, Shortcuts, webhook relays, and CLI pushes.
public actor GenericInboxConnector: InboxConnector {
    /// Source service owned by the connector.
    public let source: InboxSource = .generic
    /// Generic pushes support live local events, local backfill semantics, and deep links when supplied.
    public let capabilities: Set<InboxConnectorCapability> = [.liveEvents, .backfill, .deepLink]

    /// Creates a generic connector.
    public init() {}

    /// Returns the generic connector status.
    public func status() async -> InboxConnectorStatus {
        InboxConnectorStatus(
            source: .generic,
            accountID: "local",
            displayName: "Generic",
            status: .connected,
            message: nil,
            credentialState: .present,
            capabilities: capabilities
        )
    }

    /// Generic events are pushed directly through the hub, so sync has no remote work.
    public func sync(cursor: String?) async throws -> InboxConnectorSyncResult {
        let status = await status()
        let account = InboxAccount(
            source: .generic,
            accountID: "local",
            displayName: "Generic",
            status: .connected,
            capabilities: capabilities
        )
        return InboxConnectorSyncResult(accounts: [account], status: status)
    }

    /// Generic pushes are local only; external mark-read is a no-op after the store mutation.
    public func markRead(thread: InboxThread?, item: InboxItem?) async throws {}
}
