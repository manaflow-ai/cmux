/// Immutable presentation and routing snapshot for one agent event.
public struct MobileAgentFeedItem: Identifiable, Equatable, Sendable {
    public let id: MobileAgentFeedItemID
    public let macDeviceID: String
    public let macInstanceTag: String?
    public let macDisplayName: String
    public let connectionStatus: MobileMacConnectionStatus
    public let wire: MobileWorkstreamFeedListItem

    public init(
        macDeviceID: String,
        macInstanceTag: String?,
        macDisplayName: String,
        connectionStatus: MobileMacConnectionStatus,
        wire: MobileWorkstreamFeedListItem
    ) {
        id = MobileAgentFeedItemID(
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            eventID: wire.id.uuidString
        )
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.macDisplayName = macDisplayName
        self.connectionStatus = connectionStatus
        self.wire = wire
    }

    public var isActionable: Bool { wire.status.isPending }
}
