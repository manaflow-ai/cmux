public import CMUXMobileCore
import CmuxMobilePairedMac

extension BackingUpPairedMacStore {
    /// Forwards the atomic device-local grant and method mutation without
    /// mirroring either value into the account backup.
    public func authorizeUserTailscaleRoutesAndSetConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute],
        rawValue: String
    ) async throws {
        let resolvedTeamID = await resolvedTeam(teamID)
        try await authorizeUserTailscaleRoutesAndSetConnectionMethod(
            forwardingTo: inner,
            macDeviceID: cmxCanonicalDeviceID(macDeviceID),
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: resolvedTeamID,
            routes: routes,
            rawValue: rawValue
        )
    }
}
