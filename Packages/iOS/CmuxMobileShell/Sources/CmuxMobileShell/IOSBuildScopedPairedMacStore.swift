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

    public init(inner: any MobilePairedMacStoring, scope: MobileIOSBuildScope) {
        self.inner = inner
        self.scope = scope
    }

    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID),
            now: now
        )
    }

    public func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        var byID: [String: MobilePairedMac] = [:]
        for mac in try await inner.loadAll(stackUserID: stackUserID, teamID: scopedTeamID(teamID)).compactMap(unscoped) {
            byID[mac.macDeviceID] = mac
        }
        if normalizedTeamID(teamID) != nil {
            for mac in try await inner.loadAll(stackUserID: stackUserID, teamID: scopedTeamID(nil)).compactMap(unscoped) {
                byID[mac.macDeviceID] = byID[mac.macDeviceID] ?? mac
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
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(teamID))
    }

    public func clearActive(stackUserID: String?, teamID: String?) async throws {
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
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: scopedTeamID(teamID))
    }

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
