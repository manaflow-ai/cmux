public import CMUXMobileCore
public import Foundation

extension BackingUpPairedMacStore {
    /// Restore-only conditional write. It deliberately bypasses backup upload:
    /// the record came from that backup, and mirroring it back would create a
    /// redundant revision loop.
    @discardableResult
    public func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        try await inner.upsertIfNewer(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: await resolvedTeam(teamID),
            now: now
        )
    }
}
