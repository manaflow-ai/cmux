public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

/// A ``MobilePairedMacStoring`` decorator that injects the currently-selected
/// Stack team when shell call sites use the legacy convenience overloads.
///
/// The paired-Mac store itself supports explicit `teamID` parameters, but most
/// shell code intentionally depends on the older `loadAll(stackUserID:)` /
/// `upsert(... stackUserID:now:)` helpers. Keeping team scoping as a composition
/// decorator makes that boundary independent from backup mirroring: Release
/// builds still stamp and read rows by selected team even when the cloud backup
/// feature flag is off.
public struct TeamScopedPairedMacStore: MobilePairedMacStoring {
    private let inner: any MobilePairedMacStoring
    private let teamIDProvider: @Sendable () async -> String?

    /// Wrap a paired-Mac store with selected-team scoping.
    /// - Parameters:
    ///   - inner: The underlying paired-Mac store.
    ///   - teamIDProvider: Live selected-team lookup from the auth coordinator.
    public init(
        inner: any MobilePairedMacStoring,
        teamIDProvider: @escaping @Sendable () async -> String?
    ) {
        self.inner = inner
        self.teamIDProvider = teamIDProvider
    }

    /// Insert or update a paired Mac, using the explicit team when present or
    /// the currently-selected team otherwise.
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
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: await resolvedTeam(teamID),
            now: now
        )
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
        try await inner.upsertIfNewer(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: await resolvedTeam(teamID),
            now: now
        )
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
        try await inner.upsertRoutesIfAuthorized(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            condition: condition,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: await resolvedTeam(teamID),
            now: now
        )
    }

    /// Load paired Macs scoped to the explicit team when present or the
    /// currently-selected team otherwise.
    public func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: await resolvedTeam(teamID))
    }

    /// Return the active paired Mac scoped to the explicit team when present or
    /// the currently-selected team otherwise.
    public func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: await resolvedTeam(teamID))
    }

    /// Mark one paired Mac active in the selected team scope.
    public func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let team = await resolvedTeam(teamID)
        let visible = try await visibleMac(
            macDeviceID: macDeviceID,
            instanceTag: nil,
            stackUserID: stackUserID,
            teamID: team,
            requiresExactInstanceTag: false
        )
        try await setActive(
            macDeviceID: macDeviceID,
            instanceTag: visible?.instanceTag,
            stackUserID: stackUserID,
            teamID: team
        )
    }

    /// Mark one exact tagged Mac app instance active in the selected team scope.
    public func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let team = await resolvedTeam(teamID)
        let scope = try await visibleScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: team
        )
        if scope.teamID != team {
            try await inner.clearActive(stackUserID: scope.stackUserID, teamID: team)
        }
        try await inner.setActive(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: scope.stackUserID,
            teamID: scope.teamID
        )
    }

    /// Clear the active paired Mac in the selected team scope.
    public func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: await resolvedTeam(teamID))
    }

    /// Persist local customizations without changing the row's team scope.
    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let team = await resolvedTeam(teamID)
        let visible = try await visibleMac(
            macDeviceID: macDeviceID,
            instanceTag: nil,
            stackUserID: stackUserID,
            teamID: team,
            requiresExactInstanceTag: false
        )
        try await setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: visible?.instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: team,
            now: now
        )
    }

    /// Persist local customizations for one exact tagged app instance.
    public func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let team = await resolvedTeam(teamID)
        let scope = try await visibleScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: team
        )
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: scope.stackUserID,
            teamID: scope.teamID,
            now: now
        )
    }

    /// Remove one paired Mac in the selected team scope.
    public func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let team = await resolvedTeam(teamID)
        let visible = try await visibleMac(
            macDeviceID: macDeviceID,
            instanceTag: nil,
            stackUserID: stackUserID,
            teamID: team,
            requiresExactInstanceTag: false
        )
        try await remove(
            macDeviceID: macDeviceID,
            instanceTag: visible?.instanceTag,
            stackUserID: stackUserID,
            teamID: team
        )
    }

    /// Remove one exact tagged app instance in the selected team scope.
    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let team = await resolvedTeam(teamID)
        let scope = try await visibleScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: team
        )
        try await inner.remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: scope.stackUserID,
            teamID: scope.teamID
        )
    }

    /// Remove all paired Macs.
    public func removeAll() async throws {
        try await inner.removeAll()
    }

    private func resolvedTeam(_ teamID: String?) async -> String? {
        if let teamID { return teamID }
        return await teamIDProvider()
    }

    private func visibleScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws -> (stackUserID: String?, teamID: String?) {
        let visibleMac = try await visibleMac(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID,
            requiresExactInstanceTag: true
        )
        guard let visibleMac else {
            return (stackUserID, teamID)
        }
        return (visibleMac.stackUserID, visibleMac.teamID)
    }

    private func visibleMac(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        requiresExactInstanceTag: Bool
    ) async throws -> MobilePairedMac? {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
            .first {
                $0.macDeviceID == macDeviceID
                    && (!requiresExactInstanceTag || $0.instanceTag == instanceTag)
            }
    }
}
