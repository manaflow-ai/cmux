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

    /// Creates a store decorator that namespaces rows by the supplied iOS build scope.
    /// - Parameters:
    ///   - inner: The underlying paired-Mac store that persists scoped rows.
    ///   - scope: The build scope appended to persisted team identifiers.
    public init(inner: any MobilePairedMacStoring, scope: MobileIOSBuildScope) {
        self.inner = inner
        self.scope = scope
    }

    /// Inserts or updates a paired Mac inside this build scope.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        attachToken: String?,
        attachTokenExpiresAt: Date?,
        attachTokenWorkspaceID: String?,
        attachTokenTerminalID: String?,
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
            attachToken: attachToken,
            attachTokenExpiresAt: attachTokenExpiresAt,
            attachTokenWorkspaceID: attachTokenWorkspaceID,
            attachTokenTerminalID: attachTokenTerminalID,
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

    /// Replaces a paired Mac's routes inside this build scope.
    public func updateRoutes(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        if normalizedTeamID(teamID) != nil {
            let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
            let targetTeamID = selectedRows.contains { $0.macDeviceID == macDeviceID } ? teamID : nil
            try await inner.updateRoutes(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                stackUserID: stackUserID,
                teamID: scopedTeamID(targetTeamID),
                now: now
            )
            return
        }
        try await inner.updateRoutes(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID),
            now: now
        )
    }

    /// Loads paired Macs visible to this build scope.
    public func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        var byID: [String: MobilePairedMac] = [:]
        for mac in try await scopedRows(stackUserID: stackUserID, teamID: teamID) {
            byID[mac.macDeviceID] = mac
        }
        if normalizedTeamID(teamID) != nil {
            for mac in try await scopedRows(stackUserID: stackUserID, teamID: nil) {
                byID[mac.macDeviceID] = byID[mac.macDeviceID] ?? mac
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.macDeviceID < rhs.macDeviceID
        }
    }

    /// Returns the active paired Mac visible to this build scope.
    public func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await loadAll(stackUserID: stackUserID, teamID: teamID).first { $0.isActive }
    }

    /// Marks one paired Mac active inside this build scope.
    public func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
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

    /// Clears active paired-Mac state inside this build scope.
    public func clearActive(stackUserID: String?, teamID: String?) async throws {
        if normalizedTeamID(teamID) != nil {
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(teamID))
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(nil))
            return
        }
        try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(teamID))
    }

    /// Updates user customization for a paired Mac inside this build scope.
    public func setCustomization(
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

    /// Removes one paired Mac from this build scope.
    public func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(teamID))
        if normalizedTeamID(teamID) != nil {
            try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(nil))
        }
    }

    /// Removes all paired Macs belonging to this build scope.
    public func removeAll() async throws {
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
