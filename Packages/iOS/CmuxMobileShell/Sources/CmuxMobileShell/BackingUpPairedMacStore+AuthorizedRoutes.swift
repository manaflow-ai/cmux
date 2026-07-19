public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

extension BackingUpPairedMacStore {
    @discardableResult
    public func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        let team = await resolvedTeam(teamID)
        let existing: [MobilePairedMac]
        if let account = stackUserID, !account.isEmpty {
            existing = (try? await inner.loadAll(stackUserID: account, teamID: team)) ?? []
        } else {
            existing = []
        }
        let previousActive = markActive == true ? existing.first(where: \.isActive) : nil
        let existedBeforeWrite = existing.contains { $0.macDeviceID == macDeviceID }
        let wrote = try await inner.upsertRoutesIfAuthorized(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            condition: condition,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: team,
            now: now
        )
        guard wrote, let account = stackUserID, !account.isEmpty else { return wrote }

        lastSignedInAccount = account
        let allowsTombstoneRevive = await clearPendingDelete(
            macDeviceID: macDeviceID,
            account: account,
            teamID: team
        ) || (markActive == true && !existedBeforeWrite)
        await uploadCurrentRecord(
            macDeviceID: macDeviceID,
            account: account,
            teamID: team,
            includesCustomizations: false,
            allowTombstoneRevive: allowsTombstoneRevive,
            instanceAuthority: .compareAndSet
        )
        if markActive == true,
           let previousActive,
           previousActive.macDeviceID != macDeviceID {
            await uploadCurrentRecord(
                macDeviceID: previousActive.macDeviceID,
                account: account,
                teamID: team,
                includesCustomizations: false,
                instanceAuthority: .preserve
            )
        }
        return true
    }
}
