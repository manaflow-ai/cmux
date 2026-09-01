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
        if let atomicInner = inner as? any MobilePairedMacAtomicPairingStoring {
            try await atomicInner.authorizeUserTailscaleRoutesAndSetConnectionMethod(
                macDeviceID: cmxCanonicalDeviceID(macDeviceID),
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: resolvedTeamID,
                routes: routes,
                rawValue: rawValue
            )
        } else {
            try await inner.authorizeUserTailscaleRoutes(
                macDeviceID: cmxCanonicalDeviceID(macDeviceID),
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: resolvedTeamID,
                routes: routes
            )
            try await inner.setConnectionMethod(
                macDeviceID: cmxCanonicalDeviceID(macDeviceID),
                instanceTag: instanceTag,
                rawValue: rawValue,
                stackUserID: stackUserID,
                teamID: resolvedTeamID
            )
        }
    }
}
