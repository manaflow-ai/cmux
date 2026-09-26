public import CMUXMobileCore
public import Foundation

extension MobilePairedMacStore {
    /// Commits a verified pairing and its local endpoint authority in one SQLite transaction.
    ///
    /// - Parameters:
    ///   - macDeviceID: Authenticated device identity.
    ///   - displayName: Name reported by the authenticated host.
    ///   - routes: Destinations explicitly entered by the user.
    ///   - instanceTag: Exact app instance being paired.
    ///   - markActive: Whether to make this pairing active.
    ///   - stackUserID: Account owning the pairing and grants.
    ///   - teamID: Team owning the pairing and grants.
    ///   - now: Timestamp for the pairing metadata.
    /// - Throws: A storage error after rolling back the complete pairing operation.
    public func upsertWithUserTailscaleAuthorization(
        macDeviceID: String, displayName: String?, routes: [CmxAttachRoute],
        instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date
    ) throws {
        try Task.checkCancellation()
        try ensureReady()
        try transaction {
            try upsert(
                macDeviceID: macDeviceID, displayName: displayName, routes: routes,
                instanceTag: instanceTag, markActive: markActive,
                stackUserID: stackUserID, teamID: teamID, now: now
            )
            try authorizeUserTailscaleRoutes(
                macDeviceID: macDeviceID, instanceTag: instanceTag,
                stackUserID: stackUserID, teamID: teamID, routes: routes
            )
            // Cancellation before the commit boundary rolls back both writes.
            try Task.checkCancellation()
        }
    }
}
