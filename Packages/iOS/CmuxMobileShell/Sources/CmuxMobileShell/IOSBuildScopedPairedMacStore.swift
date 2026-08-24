public import CMUXMobileCore
public import CmuxMobilePairedMac
public import Foundation

/// Scopes the iOS saved-Mac list to one tagged iOS app build's data partition.
///
/// Mac app-instance compatibility is a separate authority boundary owned by
/// ``MobileMacBuildCompatibilityPolicy``. The composition root wraps this store
/// with that policy so one resolved policy governs discovery and persistence.
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
            : try await scopedRows(stackUserID: stackUserID, teamID: nil).first {
                matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
            }
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
                instanceTag: fallback.instanceTag,
                customName: fallback.customName,
                customColor: fallback.customColor,
                customIcon: fallback.customIcon,
                stackUserID: stackUserID,
                teamID: scopedTeamID(teamID),
                now: now
            )
            try await inner.remove(
                macDeviceID: macDeviceID,
                instanceTag: fallback.instanceTag,
                stackUserID: stackUserID,
                teamID: scopedTeamID(nil)
            )
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
        let selected = selectedRows.first {
            matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
        }
        let fallback = fallbackRows.first {
            matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
        }
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
            instanceTag: fallback?.instanceTag,
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
            let instanceTag = condition.instanceTag
            let selected = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
                .first { matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag) }
            let fallback = selectedTeam == nil
                ? nil
                : try await scopedRows(stackUserID: stackUserID, teamID: nil)
                    .first { matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag) }
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
                    instanceTag: instanceTag,
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
            byID[mac.id] = mac
        }
        if normalizedTeamID(teamID) != nil {
            // Restore/live races can briefly leave a selected-team row and its
            // teamless fallback. Newest owns each exact tagged app instance.
            for mac in try await scopedRows(stackUserID: stackUserID, teamID: nil) {
                guard let selected = byID[mac.id] else {
                    byID[mac.id] = mac
                    continue
                }
                if selected.lastSeenAt < mac.lastSeenAt {
                    var newest = mac
                    newest.isActive = selected.isActive || mac.isActive
                    byID[mac.id] = newest
                } else if mac.isActive, !selected.isActive {
                    var newest = selected
                    newest.isActive = true
                    byID[mac.id] = newest
                }
            }
        }
        return removingAuthenticatedLegacyAliases(from: Array(byID.values)).sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.id < rhs.id
        }
    }

    public func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await loadAll(stackUserID: stackUserID, teamID: teamID).first { $0.isActive }
    }

    public func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let canonicalMacDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter { cmxCanonicalDeviceID($0.macDeviceID) == canonicalMacDeviceID }
        guard matches.count == 1, let target = matches.first else { return }
        try await setActive(
            macDeviceID: target.macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    public func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await mutationGate.withLock {
            try await setActiveUnlocked(
                macDeviceID: macDeviceID, instanceTag: instanceTag,
                stackUserID: stackUserID, teamID: teamID
            )
        }
    }

    private func setActiveUnlocked(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        if normalizedTeamID(teamID) != nil {
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(teamID))
            try await inner.clearActive(stackUserID: stackUserID, teamID: scopedTeamID(nil))
            let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
            let targetTeamID = selectedRows.contains {
                matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
            } ? teamID : nil
            try await inner.setActive(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: scopedTeamID(targetTeamID)
            )
            return
        }
        try await inner.setActive(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID)
        )
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
        let canonicalMacDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter { cmxCanonicalDeviceID($0.macDeviceID) == canonicalMacDeviceID }
        guard matches.count == 1, let target = matches.first else { return }
        try await setCustomization(
            macDeviceID: target.macDeviceID,
            instanceTag: target.instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    /// Device-local per-Computer Direct addresses; same build-scoped owner
    /// key rule as `setConnectionMethod`.
    public func setDirectAddresses(
        macDeviceID: String,
        instanceTag: String?,
        rawJSON: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await mutationGate.withLock {
            if normalizedTeamID(teamID) != nil {
                let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
                let targetTeamID = selectedRows.contains {
                    matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
                } ? teamID : nil
                try await inner.setDirectAddresses(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    rawJSON: rawJSON,
                    stackUserID: stackUserID,
                    teamID: scopedTeamID(targetTeamID)
                )
                return
            }
            try await inner.setDirectAddresses(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                rawJSON: rawJSON,
                stackUserID: stackUserID,
                teamID: scopedTeamID(teamID)
            )
        }
    }

    /// Device-local per-Computer connection method. The stored row's owner
    /// key embeds this store's BUILD-SCOPED team id, so the team must go
    /// through `scopedTeamID` exactly like `setCustomizationUnlocked` — a
    /// verbatim team id updates zero rows.
    public func setConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        rawValue: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await mutationGate.withLock {
            if normalizedTeamID(teamID) != nil {
                let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
                let targetTeamID = selectedRows.contains {
                    matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
                } ? teamID : nil
                try await inner.setConnectionMethod(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    rawValue: rawValue,
                    stackUserID: stackUserID,
                    teamID: scopedTeamID(targetTeamID)
                )
                return
            }
            try await inner.setConnectionMethod(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                rawValue: rawValue,
                stackUserID: stackUserID,
                teamID: scopedTeamID(teamID)
            )
        }
    }

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
        try await mutationGate.withLock {
            try await setCustomizationUnlocked(
                macDeviceID: macDeviceID, instanceTag: instanceTag, customName: customName,
                customColor: customColor, customIcon: customIcon,
                stackUserID: stackUserID, teamID: teamID, now: now
            )
        }
    }

    private func setCustomizationUnlocked(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        if normalizedTeamID(teamID) != nil {
            let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
            let targetTeamID = selectedRows.contains {
                matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
            } ? teamID : nil
            try await inner.setCustomization(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
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
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID),
            now: now
        )
    }

    public func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let canonicalMacDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter { cmxCanonicalDeviceID($0.macDeviceID) == canonicalMacDeviceID }
        guard matches.count == 1, let target = matches.first else { return }
        try await remove(
            macDeviceID: target.macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await mutationGate.withLock {
            try await removeUnlocked(
                macDeviceID: macDeviceID, instanceTag: instanceTag,
                stackUserID: stackUserID, teamID: teamID
            )
        }
    }

    private func removeUnlocked(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await inner.remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID)
        )
        if normalizedTeamID(teamID) != nil {
            try await inner.remove(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: scopedTeamID(nil)
            )
        }
    }

    /// Exact-scope removal deletes ONLY the row at `scopedTeamID(teamID)` and
    /// never the team-less build-scope fallback (`scopedTeamID(nil)`) that
    /// `removeUnlocked` also drops for the general `remove`. The forget flow has
    /// already captured the row's own team, so there is no nil `teamID` to
    /// re-resolve here; over-deleting the fallback would discard an unrelated
    /// team-less pairing that shares this build scope. Runs inside `mutationGate`
    /// so it cannot race a concurrent upsert.
    public func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await mutationGate.withLock {
            try await inner.removeExactScope(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: scopedTeamID(teamID)
            )
        }
    }

    /// Cross-team enumeration bounded to THIS build scope: rows from other
    /// build scopes are invisible, exactly like every other read here. The
    /// inner enumeration is cross-team over scoped team ids; keep only rows
    /// carrying this scope's suffix and unwrap them to client team ids.
    public func loadAllInstances(
        macDeviceID: String,
        stackUserID: String?
    ) async throws -> [MobilePairedMac] {
        try await inner.loadAllInstances(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID
        )
        .compactMap(unscoped)
    }

    public func removeAll() async throws {
        try await mutationGate.withLock {
            try await removeAllUnlocked()
        }
    }

    public func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {
        // Mirror setCustomizationUnlocked: write to the scope that actually
        // holds the row, falling back to the team-less scope when the selected
        // team has no matching row, so the base store's exact-row requirement
        // cannot silently drop a user-entered grant.
        if normalizedTeamID(teamID) != nil {
            let selectedRows = try await scopedRows(stackUserID: stackUserID, teamID: teamID)
            let targetTeamID = selectedRows.contains {
                matches($0, macDeviceID: macDeviceID, instanceTag: instanceTag)
            } ? teamID : nil
            try await inner.authorizeUserTailscaleRoutes(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: stackUserID,
                teamID: scopedTeamID(targetTeamID),
                routes: routes
            )
            return
        }
        try await inner.authorizeUserTailscaleRoutes(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: scopedTeamID(teamID),
            routes: routes
        )
    }

    private func removeAllUnlocked() async throws {
        for mac in try await inner.loadAll(stackUserID: nil, teamID: nil) where isScoped(mac) {
            try await inner.remove(
                macDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                stackUserID: mac.stackUserID,
                teamID: mac.teamID
            )
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

    private func matches(
        _ mac: MobilePairedMac,
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        MacPairingKey(mac) == MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }

    /// A legacy nil-tag row and a tagged row are the same app instance only
    /// when both the physical Mac id and authenticated Iroh peer id match.
    /// Distinct tagged builds and legacy rows for other peers remain visible.
    private func removingAuthenticatedLegacyAliases(
        from rows: [MobilePairedMac]
    ) -> [MobilePairedMac] {
        var taggedPeersByMacDeviceID: [String: Set<String>] = [:]
        for mac in rows where mac.instanceTag?.isEmpty == false {
            taggedPeersByMacDeviceID[cmxCanonicalDeviceID(mac.macDeviceID), default: []]
                .formUnion(irohPeerEndpointIDs(in: mac.routes))
        }
        return rows.filter { mac in
            guard mac.instanceTag == nil,
                  let taggedPeers = taggedPeersByMacDeviceID[cmxCanonicalDeviceID(mac.macDeviceID)] else {
                return true
            }
            return taggedPeers.isDisjoint(with: irohPeerEndpointIDs(in: mac.routes))
        }
    }

    private func irohPeerEndpointIDs(in routes: [CmxAttachRoute]) -> Set<String> {
        Set(routes.compactMap { route in
            guard route.kind == .iroh,
                  case let .peer(identity, _) = route.endpoint else {
                return nil
            }
            return identity.endpointID
        })
    }
}

private extension MobilePairedMacRouteWriteCondition {
    var instanceTag: String? {
        switch self {
        case .matchingInstanceTag(let instanceTag): instanceTag
        case .unclaimed: nil
        }
    }
}
