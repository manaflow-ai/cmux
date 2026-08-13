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

    /// Whether this row can represent work awaiting a response. Turn-complete
    /// rows still need collection context so only the latest turn is offered.
    public var isActionable: Bool {
        wire.status.isPending || isTurnCompletion
    }

    /// Whether this row marks a point where another prompt can continue the agent.
    public var isTurnCompletion: Bool {
        switch wire.payload {
        case .stop:
            return true
        case .lifecycle:
            return wire.kind == "sessionEnd"
        default:
            return false
        }
    }
}
