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
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let team = await resolvedTeam(teamID)
        let existing: [MobilePairedMac]
        if let account = stackUserID, !account.isEmpty {
            existing = (try? await inner.loadAll(stackUserID: account, teamID: team)) ?? []
        } else {
            existing = []
        }
        let instanceTag: String?
        switch condition {
        case .matchingInstanceTag(let expectedInstanceTag):
            instanceTag = expectedInstanceTag
        case .unclaimed:
            instanceTag = nil
        }
        let previousActive = markActive == true ? existing.first(where: \.isActive) : nil
        let existedBeforeWrite = existing.contains {
            cmxCanonicalDeviceID($0.macDeviceID) == macDeviceID
                && $0.instanceTag == instanceTag
        }
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
            instanceTag: instanceTag,
            account: account,
            teamID: team
        ) || (markActive == true && !existedBeforeWrite)
        await uploadCurrentRecord(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            account: account,
            teamID: team,
            includesCustomizations: false,
            allowTombstoneRevive: allowsTombstoneRevive,
            instanceAuthority: .compareAndSet
        )
        if markActive == true,
           let previousActive,
           previousActive.id != MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
           ) {
            await uploadCurrentRecord(
                macDeviceID: previousActive.macDeviceID,
                instanceTag: previousActive.instanceTag,
                account: account,
                teamID: team,
                includesCustomizations: false,
                instanceAuthority: .preserve
            )
        }
        return true
    }
}
