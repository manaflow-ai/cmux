import CMUXMobileCore

struct MacPairedMacBackupRecordWire: Encodable {
    let macDeviceID: String
    let displayName: String?
    let routes: [CmxAttachRoute]
    /// Mac app-instance identity that atomically owns `routes`.
    let instanceTag: String
    /// The Mac self-publisher may refresh only an unclaimed or same-tag record;
    /// an explicit authenticated iOS pairing owns cross-tag switches.
    let instanceTagWriteMode = "compare_and_set"
    let createdAt: Double
    let lastSeenAt: Double
    let isActive: Bool
}
