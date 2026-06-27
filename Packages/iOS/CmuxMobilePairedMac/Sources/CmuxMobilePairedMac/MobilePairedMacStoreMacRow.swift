import Foundation

nonisolated struct MobilePairedMacStoreMacRow {
    let macDeviceID: String
    let ownerKey: String
    let displayName: String?
    let stackUserID: String?
    var teamID: String? = nil
    let createdAt: Date
    let lastSeenAt: Date
    let isActive: Bool
    var customName: String? = nil
    var customColor: String? = nil
    var customIcon: String? = nil
    var attachTokenExpiresAt: Date? = nil
    var attachTokenWorkspaceID: String? = nil
    var attachTokenTerminalID: String? = nil
}
