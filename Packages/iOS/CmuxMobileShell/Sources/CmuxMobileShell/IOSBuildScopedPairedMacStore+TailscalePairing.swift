public import CMUXMobileCore
import CmuxMobilePairedMac

extension IOSBuildScopedPairedMacStore {
    /// Atomically forwards a user Tailscale grant plus method selection through
    /// the build-scoped mutation gate and row-scope resolver.
    public func authorizeUserTailscaleRoutesAndSetConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute],
        rawValue: String
    ) async throws {
        try await mutationGate.withLock {
            if normalizedTeamID(teamID) != nil {
                let selectedRows = try await scopedRows(
                    stackUserID: stackUserID,
                    teamID: teamID
                )
                let targetTeamID = selectedRows.contains {
                    matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
                } ? teamID : nil
                try await persistPairing(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    stackUserID: stackUserID,
                    teamID: scopedTeamID(targetTeamID),
                    routes: routes,
                    rawValue: rawValue
                )
                return
            }
            try await persistPairing(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: scopedTeamID(teamID),
                routes: routes,
                rawValue: rawValue
            )
        }
    }

    private func persistPairing(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute],
        rawValue: String
    ) async throws {
        if let atomicInner = inner as? any MobilePairedMacAtomicPairingStoring {
            try await atomicInner.authorizeUserTailscaleRoutesAndSetConnectionMethod(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: teamID,
                routes: routes,
                rawValue: rawValue
            )
        } else {
            try await inner.authorizeUserTailscaleRoutes(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: teamID,
                routes: routes
            )
            try await inner.setConnectionMethod(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                rawValue: rawValue,
                stackUserID: stackUserID,
                teamID: teamID
            )
        }
    }
}
