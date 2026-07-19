public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

/// Scopes the iOS saved-Mac list to one tagged iOS app build.
///
/// QR pairing still accepts any Mac build because the Mac's device id and routes
/// are unchanged. This decorator only decides where that successful pairing is
/// stored, so two iOS dev tags stop restoring or aggregating each other's saved
/// Macs.
public struct IOSBuildScopedPairedMacStore: MobilePairedMacStoring {
    private static let separator = "\u{1F}"

    private let inner: any MobilePairedMacStoring
    private let scope: MobileIOSBuildScope
    private let mutationGate: PairedMacMutationGate

    public init(inner: any MobilePairedMacStoring, scope: MobileIOSBuildScope) {
        self.inner = inner
        self.scope = scope
        self.mutationGate = PairedMacMutationGate()
    }

    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await mutationGate.withLock {
            try await upsertUnlocked(
                macDeviceID: macDeviceID, displayName: displayName,
                routes: routes, instanceTag: instanceTag, markActive: markActive,
                stackUserID: stackUserID, teamID: teamID, now: now
            )
        }
    }

    private func upsertUnlocked(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let selectedTeam = normalizedTeamID(teamID)
        let fallback = selectedTeam == nil
            ? nil
            : try await scopedRows(stackUserID: stackUserID, teamID: nil).first { $0.macDeviceID == macDeviceID }
        if markActive, selectedTeam != nil {
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(nil))
        }
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID),
            now: now
        )
        if let fallback, selectedTeam != nil {
            try await inner.setCustomization(
                macDeviceID: macDeviceID,
                customName: fallback.customName,
                customColor: fallback.customColor,
                customIcon: fallback.customIcon,
                stackUserID: stackUserID,
                teamID: scopedTeamID(teamID),
                now: now
            )
            try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(nil))
        }
    }

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
        try await mutationGate.withLock {
            try await upsertIfNewerUnlocked(
                macDeviceID: macDeviceID, displayName: displayName,
                routes: routes, instanceTag: instanceTag,
                customName: customName, customColor: customColor,
                customIcon: customIcon, markActive: markActive,
                stackUserID: stackUserID, teamID: teamID, now: now
            )
        }
    }

    private func upsertIfNewerUnlocked(
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
        let selectedTeam = normalizedTeamID(teamID)
        let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
        let fallbackRows = selectedTeam == nil
            ? []
            : try await scopedRows(stackUserID: stackUserID, teamID: nil)
        let selected = selectedRows.first { $0.macDeviceID == macDeviceID }
        let fallback = fallbackRows.first { $0.macDeviceID == macDeviceID }
        if let fallback, fallback.lastSeenAt >= now { return false }
        let currentTargetIsActive = selected?.isActive == true || fallback?.isActive == true
        let logicalScopeHasActive = (selectedRows + fallbackRows).contains(where: \.isActive)
        let restoreMarkActive = selected != nil || fallback != nil
            ? currentTargetIsActive
            : (markActive && !logicalScopeHasActive)
        let wrote = try await inner.upsertIfNewer(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            markActive: restoreMarkActive,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID),
            now: now
        )
        guard wrote, fallback != nil, selectedTeam != nil else { return wrote }
        try await inner.remove(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: scopedTeamID(nil)
        )
        return true
    }

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
        try await mutationGate.withLock {
            let selectedTeam = normalizedTeamID(teamID)
            let selected = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
                .first { $0.macDeviceID == macDeviceID }
            let fallback = selectedTeam == nil
                ? nil
                : try await scopedRows(stackUserID: stackUserID, teamID: nil)
                    .first { $0.macDeviceID == macDeviceID }
            let targetsFallback = fallback.map {
                selected == nil || (selected?.lastSeenAt ?? .distantPast) < $0.lastSeenAt
            } ?? false
            let targetTeamID = targetsFallback ? nil : teamID
            let wrote = try await inner.upsertRoutesIfAuthorized(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                condition: condition,
                // Active selection spans selected-team and legacy fallback rows,
                // so apply activation through this decorator after authority wins.
                markActive: markActive == true ? nil : markActive,
                stackUserID: stackUserID,
                teamID: scopedTeamID(targetTeamID),
                now: now
            )
            if wrote, markActive == true {
                try await setActiveUnlocked(
                    macDeviceID: macDeviceID,
                    stackUserID: stackUserID,
                    teamID: teamID
                )
            }
            return wrote
        }
    }

    public func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        var byID: [String: MobilePairedMac] = [:]
        for mac in try await scopedRows(stackUserID: stackUserID, teamID: teamID) {
            byID[mac.macDeviceID] = mac
        }
        if normalizedTeamID(teamID) != nil {
            // Restore/live races can briefly leave a selected-team row and its
            // teamless fallback. Newest owns the host tuple; active is logical
            // per physical Mac, so preserve it across the duplicate rows.
            for mac in try await scopedRows(stackUserID: stackUserID, teamID: nil) {
                guard let selected = byID[mac.macDeviceID] else {
                    byID[mac.macDeviceID] = mac
                    continue
                }
                if selected.lastSeenAt < mac.lastSeenAt {
                    var newest = mac
                    newest.isActive = selected.isActive || mac.isActive
                    byID[mac.macDeviceID] = newest
                } else if mac.isActive, !selected.isActive {
                    var newest = selected
                    newest.isActive = true
                    byID[mac.macDeviceID] = newest
                }
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.macDeviceID < rhs.macDeviceID
        }
    }

    public func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await loadAll(stackUserID: stackUserID, teamID: teamID).first { $0.isActive }
    }

    public func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await mutationGate.withLock {
            try await setActiveUnlocked(
                macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID
            )
        }
    }

    private func setActiveUnlocked(
        macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        if normalizedTeamID(teamID) != nil {
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(teamID))
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(nil))
            let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
            let targetTeamID = selectedRows.contains { $0.macDeviceID == macDeviceID } ? teamID : nil
            try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(targetTeamID))
            return
        }
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(teamID))
    }

    public func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await mutationGate.withLock {
            try await clearActiveUnlocked(stackUserID: stackUserID, teamID: teamID)
        }
    }

    private func clearActiveUnlocked(stackUserID: String?, teamID: String?) async throws {
        if normalizedTeamID(teamID) != nil {
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(teamID))
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(nil))
            return
        }
        try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(teamID))
    }

    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await mutationGate.withLock {
            try await setCustomizationUnlocked(
                macDeviceID: macDeviceID, customName: customName,
                customColor: customColor, customIcon: customIcon,
                stackUserID: stackUserID, teamID: teamID, now: now
            )
        }
    }

    private func setCustomizationUnlocked(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        if normalizedTeamID(teamID) != nil {
            let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
            let targetTeamID = selectedRows.contains { $0.macDeviceID == macDeviceID } ? teamID : nil
            try await inner.setCustomization(
                macDeviceID: macDeviceID,
                customName: customName,
                customColor: customColor,
                customIcon: customIcon,
                stackUserID: stackUserID,
                teamID: scopedTeamID(targetTeamID),
                now: now
            )
            return
        }
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID),
            now: now
        )
    }

    public func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await mutationGate.withLock {
            try await removeUnlocked(
                macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID
            )
        }
    }

    private func removeUnlocked(
        macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(teamID))
        if normalizedTeamID(teamID) != nil {
            try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(nil))
        }
    }

    public func removeAll() async throws {
        try await mutationGate.withLock {
            try await removeAllUnlocked()
        }
    }

    private func removeAllUnlocked() async throws {
        for mac in try await inner.loadAll(stackUserID: nil, teamID: nil) where isScoped(mac) {
            try await inner.remove(macDeviceID: mac.macDeviceID, stackUserID: mac.stackUserID, teamID: mac.teamID)
        }
    }

    private func scopedTeamID(_ teamID: String?) -> String {
        let team = normalizedTeamID(teamID) ?? ""
        return "\(team)\(Self.separator)\(scope.serializedScope)"
    }

    private func normalizedTeamID(_ teamID: String?) -> String? {
        let team = teamID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return team.isEmpty ? nil : team
    }

    private func scopedRows(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: scopedTeamID(teamID)).compactMap(unscoped)
    }

    private func unscoped(_ mac: MobilePairedMac) -> MobilePairedMac? {
        guard let teamID = mac.teamID else { return nil }
        let suffix = scopedSuffix
        guard teamID.hasSuffix(suffix) else { return nil }
        let rawTeam = String(teamID.dropLast(suffix.count))
        var copy = mac
        copy.teamID = rawTeam.isEmpty ? nil : rawTeam
        return copy
    }

    private func isScoped(_ mac: MobilePairedMac) -> Bool {
        mac.teamID?.hasSuffix(scopedSuffix) == true
    }

    private var scopedSuffix: String {
        "\(Self.separator)\(scope.serializedScope)"
    }
}
