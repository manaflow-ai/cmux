import CMUXMobileCore

public struct MacPairedMacBackupRecordWire: Encodable, Sendable {
    public init(
        macDeviceID: String,
        displayName: String? = nil,
        routes: [CmxAttachRoute],
        instanceTag: String,
        createdAt: Double,
        lastSeenAt: Double,
        isActive: Bool
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.instanceTag = instanceTag
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
    }

    public let macDeviceID: String
    public let displayName: String?
    public let routes: [CmxAttachRoute]
    /// Mac app-instance identity that atomically owns `routes`.
    public let instanceTag: String
    /// The Mac self-publisher may refresh only an unclaimed or same-tag record;
    /// an explicit authenticated iOS pairing owns cross-tag switches.
    public let instanceTagWriteMode = "compare_and_set"
    public let createdAt: Double
    public let lastSeenAt: Double
    public let isActive: Bool
}
