import CMUXMobileCore

struct MacPairedMacBackupRecordWire: Encodable {
    let macDeviceID: String
    let displayName: String?
    let routes: [CmxAttachRoute]
    let createdAt: Double
    let lastSeenAt: Double
    let isActive: Bool
}
