#if DEBUG
import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

actor HideComputersVerifierPairedMacStore: MobilePairedMacStoring {
    private var records: [MobilePairedMac]

    init(records: [MobilePairedMac]) {
        self.records = records
    }

    private func isVisibleInLoadScope(
        _ mac: MobilePairedMac,
        stackUserID: String?,
        teamID: String?
    ) -> Bool {
        if let stackUserID, mac.stackUserID != stackUserID {
            return false
        }
        guard let teamID else { return true }
        return mac.teamID == teamID || mac.teamID == nil
    }

    private func isVisibleInActiveScope(
        _ mac: MobilePairedMac,
        stackUserID: String?,
        teamID: String?
    ) -> Bool {
        if let stackUserID, mac.stackUserID != stackUserID {
            return false
        }
        if let teamID {
            return mac.teamID == teamID || mac.teamID == nil
        }
        return mac.teamID == nil
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        if markActive {
            records = records.map { mac in
                var copy = mac
                if isVisibleInActiveScope(copy, stackUserID: stackUserID, teamID: teamID) {
                    copy.isActive = false
                }
                return copy
            }
        }
        if let index = records.firstIndex(where: {
            $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
        }) {
            records[index].displayName = displayName
            records[index].routes = routes
            records[index].instanceTag = instanceTag
            records[index].lastSeenAt = now
            records[index].isActive = markActive
            records[index].stackUserID = stackUserID
            records[index].teamID = teamID
        } else {
            records.append(MobilePairedMac(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                createdAt: now,
                lastSeenAt: now,
                isActive: markActive,
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            ))
        }
    }

    @discardableResult
    func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        let expectedInstanceTag: String?
        switch condition {
        case .matchingInstanceTag(let tag):
            expectedInstanceTag = tag
        case .unclaimed:
            expectedInstanceTag = nil
        }
        let index = records.firstIndex {
            $0.macDeviceID == macDeviceID
                && $0.instanceTag == expectedInstanceTag
                && isVisibleInLoadScope($0, stackUserID: stackUserID, teamID: teamID)
        }
        switch condition {
        case .matchingInstanceTag:
            guard index != nil else { return false }
        case .unclaimed:
            let hasClaimedSibling = records.contains {
                $0.macDeviceID == macDeviceID
                    && $0.instanceTag != nil
                    && isVisibleInLoadScope($0, stackUserID: stackUserID, teamID: teamID)
            }
            guard !hasClaimedSibling else { return false }
        }
        if markActive == true {
            records = records.map { mac in
                var copy = mac
                if isVisibleInActiveScope(copy, stackUserID: stackUserID, teamID: teamID) {
                    copy.isActive = false
                }
                return copy
            }
        }
        if let index {
            records[index].displayName = displayName
            records[index].routes = routes
            records[index].lastSeenAt = now
            if let markActive { records[index].isActive = markActive }
        } else {
            records.append(MobilePairedMac(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                createdAt: now,
                lastSeenAt: now,
                isActive: markActive ?? false,
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: expectedInstanceTag
            ))
        }
        return true
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        records
            .filter { isVisibleInLoadScope($0, stackUserID: stackUserID, teamID: teamID) }
            .sorted { lhs, rhs in
                if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
                return lhs.macDeviceID < rhs.macDeviceID
            }
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await loadAll(stackUserID: stackUserID, teamID: teamID).first { $0.isActive }
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let matches = records.filter {
            $0.macDeviceID == macDeviceID
                && isVisibleInActiveScope($0, stackUserID: stackUserID, teamID: teamID)
        }
        guard matches.count == 1, let target = matches.first else { return }
        try await setActive(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        records = records.map { mac in
            var copy = mac
            if isVisibleInActiveScope(copy, stackUserID: stackUserID, teamID: teamID) {
                copy.isActive = copy.macDeviceID == macDeviceID
                    && copy.instanceTag == instanceTag
            }
            return copy
        }
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        records = records.map { mac in
            var copy = mac
            if isVisibleInActiveScope(copy, stackUserID: stackUserID, teamID: teamID) {
                copy.isActive = false
            }
            return copy
        }
    }

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let matches = records.indices.filter {
            records[$0].macDeviceID == macDeviceID
                && records[$0].stackUserID == stackUserID
                && records[$0].teamID == teamID
        }
        guard matches.count == 1, let index = matches.first else { return }
        records[index].customName = customName
        records[index].customColor = customColor
        records[index].customIcon = customIcon
        records[index].lastSeenAt = now
    }

    func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard let index = records.firstIndex(where: {
            $0.macDeviceID == macDeviceID
                && $0.instanceTag == instanceTag
                && $0.stackUserID == stackUserID
                && $0.teamID == teamID
        }) else { return }
        records[index].customName = customName
        records[index].customColor = customColor
        records[index].customIcon = customIcon
        records[index].lastSeenAt = now
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let matches = records.filter {
            $0.macDeviceID == macDeviceID
                && $0.stackUserID == stackUserID
                && $0.teamID == teamID
        }
        guard matches.count == 1, let target = matches.first else { return }
        try await remove(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        records.removeAll {
            $0.macDeviceID == macDeviceID
                && $0.instanceTag == instanceTag
                && $0.stackUserID == stackUserID
                && $0.teamID == teamID
        }
    }

    func removeAll() async throws {
        records.removeAll()
    }

    // The hide-computers verifier only checks row visibility; grants are
    // irrelevant to it and are not modeled.
    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {}
}
#endif
