/// One per-Mac notification source plus the connection status to project onto
/// retained rows during aggregation.
public struct MobileNotificationFeedSourceSnapshot: Sendable {
    /// The source Mac's retained notifications, newest first.
    public let items: [MobileNotificationFeedItem]
    /// The source Mac's current connection status, when one should be projected onto retained rows.
    public let connectionStatus: MobileMacConnectionStatus?

    /// Creates one source snapshot for cross-Mac notification aggregation.
    public init(
        items: [MobileNotificationFeedItem],
        connectionStatus: MobileMacConnectionStatus? = nil
    ) {
        self.items = items
        self.connectionStatus = connectionStatus
    }
}
