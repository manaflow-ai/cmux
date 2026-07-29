import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
internal import OSLog

private let hiddenMacsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

@MainActor
extension MobileShellComposite {
    func storedHiddenMacDeviceIDs(scopeKey key: String) async -> Set<String> {
        if let cached = hiddenMacDeviceIDsByScope[key] { return cached }
        let loaded = await hiddenMacStore.load(scope: key)
        if let cached = hiddenMacDeviceIDsByScope[key] {
            return cached
        }
        hiddenMacDeviceIDsByScope[key] = loaded
        return loaded
    }

    func hiddenMacDeviceIDs(scope: MobileShellScopeSnapshot) async -> Set<String> {
        let key = pairedMacScopeKey(scope)
        let scoped = await storedHiddenMacDeviceIDs(scopeKey: key)
        guard scope.teamID != nil else { return scoped }
        let userWide = await storedHiddenMacDeviceIDs(
            scopeKey: pairedMacScopeKey(userWideScope(from: scope))
        )
        return scoped.union(userWide)
    }

    func visibleStoredPairedMacs(
        from loadedMacs: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) async -> [MobilePairedMac] {
        let hiddenIDs = await hiddenMacDeviceIDs(scope: scope)
        return visibleStoredPairedMacs(from: loadedMacs, hiddenIDs: hiddenIDs)
    }

    func visibleStoredPairedMacs(
        from loadedMacs: [MobilePairedMac],
        hiddenIDs: Set<String>
    ) -> [MobilePairedMac] {
        return loadedMacs.filter {
            !hiddenIDs.contains($0.id) && !hiddenIDs.contains($0.macDeviceID)
        }
    }

    /// Clears rowless markers written by the legacy delete flow.
    ///
    /// Both pairing ids and raw device ids were historically stored as markers,
    /// so either form keeps the marker when it matches a local row.
    func migrateLegacyHiddenMacMarkers(
        loadedMacs: [MobilePairedMac],
        hiddenIDs: Set<String>,
        scope: MobileShellScopeSnapshot
    ) async -> Set<String> {
        let rowBackedIDs = Set(loadedMacs.flatMap { [$0.id, $0.macDeviceID] })
        let rowlessIDs = hiddenIDs.subtracting(rowBackedIDs)
        guard !rowlessIDs.isEmpty else { return hiddenIDs }

        var scopeKeys = Set([pairedMacScopeKey(scope)])
        if scope.teamID != nil {
            scopeKeys.insert(pairedMacScopeKey(userWideScope(from: scope)))
        }
        for scopeKey in scopeKeys {
            for rowlessID in rowlessIDs {
                await clearHiddenMacDeviceID(rowlessID, scopeKey: scopeKey)
            }
        }
        hiddenMacsLog.info(
            "legacy hidden-marker migration cleared=\(rowlessIDs.count) kept=\(hiddenIDs.count - rowlessIDs.count) rows=\(loadedMacs.count)"
        )
        return hiddenIDs.subtracting(rowlessIDs)
    }

    func isHiddenMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        let ids = await hiddenMacDeviceIDs(scope: scope)
        return ids.contains(macDeviceID) || ids.contains(MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ))
    }

    func rememberHiddenMacDeviceID(
        _ macDeviceID: String,
        scope: MobileShellScopeSnapshot,
        includeUserWideScope: Bool = false
    ) async {
        guard !macDeviceID.isEmpty else { return }
        await rememberHiddenMacDeviceID(macDeviceID, scopeKey: pairedMacScopeKey(scope))
        if includeUserWideScope, scope.teamID != nil {
            await rememberHiddenMacDeviceID(
                macDeviceID,
                scopeKey: pairedMacScopeKey(userWideScope(from: scope))
            )
        }
        let identity = MobilePairedMac.pairingIdentity(from: macDeviceID)
        registryDevices.removeAll {
            $0.deviceId == macDeviceID || $0.deviceId == identity.macDeviceID
        }
    }

    func rememberHiddenMacDeviceID(_ macDeviceID: String, scopeKey key: String) async {
        var ids = await storedHiddenMacDeviceIDs(scopeKey: key)
        ids.insert(macDeviceID)
        hiddenMacDeviceIDsByScope[key] = ids
        await hiddenMacStore.save(ids, scope: key)
    }

    func clearHiddenMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil,
        scope: MobileShellScopeSnapshot?
    ) async {
        guard !macDeviceID.isEmpty, let scope else { return }
        let ids = Set([
            macDeviceID,
            MobilePairedMac.pairingID(macDeviceID: macDeviceID, instanceTag: instanceTag),
        ])
        for id in ids {
            await clearHiddenMacDeviceID(id, scopeKey: pairedMacScopeKey(scope))
        }
        if scope.teamID != nil {
            for id in ids {
                await clearHiddenMacDeviceID(
                    id,
                    scopeKey: pairedMacScopeKey(userWideScope(from: scope))
                )
            }
        }
    }

    func clearHiddenMacDeviceID(_ macDeviceID: String, scopeKey key: String) async {
        var ids = await storedHiddenMacDeviceIDs(scopeKey: key)
        guard ids.remove(macDeviceID) != nil else { return }
        hiddenMacDeviceIDsByScope[key] = ids
        await hiddenMacStore.save(ids, scope: key)
        if ids.isEmpty {
            hiddenMacDeviceIDsByScope[key] = nil
        }
    }

    /// Revokes a hidden computer's account bindings, then drops its local row.
    ///
    /// The revoke is the meaningful action: it removes the binding from every
    /// device on the account. On success the paired-Mac row and its hidden
    /// marker are cleared so the computer disappears from every section; a Mac
    /// that is still online re-registers a fresh binding and reappears on its
    /// next connect. Returns `false` (leaving the row untouched) when no forget
    /// capability is wired or the revoke fails, so the caller can surface an
    /// error instead of a silent no-op.
    public func forgetHiddenComputer(_ computer: MobileHiddenComputer) async -> Bool {
        guard let personalIrohForget else { return false }
        // Capture the scope BEFORE the network revoke so local cleanup targets the
        // account/team that owned the row, not whatever scope is current after the
        // await (the user can sign out or switch accounts while the call is in
        // flight).
        guard let scope = await currentScopeSnapshot() else { return false }
        do {
            // Pin the revoke to the ROW's owning account, not the live session.
            // A row owned by account A can still be on screen right after auth
            // switches to account B (the list has not refreshed yet). The runtime
            // forget checks this pinned account against the live session and fails
            // closed on a mismatch, so passing the live account here would let it
            // revoke B's matching device/tag while local cleanup deletes A's row.
            // `computer.stackUserID` is the row's captured owner; fall back to the
            // display scope only for a legacy row that never stored one.
            try await personalIrohForget.forgetComputer(
                macDeviceID: computer.macDeviceID,
                instanceTag: computer.instanceTag,
                expectedAccountID: computer.stackUserID ?? scope.userID
            )
        } catch {
            hiddenMacsLog.error(
                "forget hidden computer revoke failed: \(String(describing: error), privacy: .private)"
            )
            return false
        }
        // A tag-less row cannot name its own binding, so the revoke above was the
        // device-wide wildcard (every tag of this device, for the pinned account).
        // Local cleanup must match that breadth: the device's coexisting tagged
        // rows just lost their bindings too, and leaving them saved strands dead
        // entries in the computer list until the Mac happens to re-register. Each
        // sibling is deleted by its OWN exact scope. Rows owned by a different
        // account keep their bindings (the revoke was account-pinned) and stay.
        var siblingsCleaned = true
        if computer.instanceTag == nil {
            siblingsCleaned = await removeWildcardSiblingRows(
                macDeviceID: computer.macDeviceID,
                pinnedAccountID: computer.stackUserID ?? scope.userID,
                displayScope: scope
            )
        }
        // Always clear the durable row and hidden marker, even if the scope changed
        // while the revoke was in flight. The row is deleted against ITS OWN stored
        // scope (`computer.stackUserID`/`computer.teamID`), not the live display
        // scope: a team-less row is visible under any selected team (legacy
        // visibility), so deleting with the display team would miss the team-less
        // row and it would resurface once the marker cleared. The hidden marker and
        // on-screen refresh still gate on the captured display `scope` (that is how
        // the marker was keyed when the row was hidden). Skipping this would report
        // success while leaving the row behind, so returning to the old scope would
        // show the supposedly forgotten computer.
        let primaryCleaned = await removeStoredPairedMacRow(
            macDeviceID: computer.macDeviceID,
            instanceTag: computer.instanceTag,
            rowStackUserID: computer.stackUserID ?? scope.userID,
            rowTeamID: computer.teamID,
            displayScope: scope
        )
        return siblingsCleaned && primaryCleaned
    }

    /// Deletes the device's OTHER (tagged) rows after a wildcard forget, so the
    /// local list matches the revoke's breadth.
    ///
    /// Enumerates what the store can see in the captured display scope (the
    /// display team plus team-less legacy rows) and deletes only rows owned by
    /// the account the revoke was pinned to, each through the same exact-scope
    /// removal as the primary row (which also clears its hidden marker). Rows in
    /// OTHER teams' scopes are not enumerable here and self-heal when the Mac
    /// re-registers; rows owned by other accounts still hold live bindings and
    /// must survive.
    private func removeWildcardSiblingRows(
        macDeviceID: String,
        pinnedAccountID: String,
        displayScope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard let pairedMacStore else { return true }
        let canonical = cmxCanonicalDeviceID(macDeviceID)
        let rows = (try? await pairedMacStore.loadAll(
            stackUserID: pinnedAccountID,
            teamID: displayScope.teamID
        )) ?? []
        var allCleaned = true
        for row in rows
        where cmxCanonicalDeviceID(row.macDeviceID) == canonical
            && row.instanceTag != nil
            && row.stackUserID == pinnedAccountID {
            let cleaned = await removeStoredPairedMacRow(
                macDeviceID: row.macDeviceID,
                instanceTag: row.instanceTag,
                rowStackUserID: pinnedAccountID,
                rowTeamID: row.teamID,
                displayScope: displayScope
            )
            allCleaned = allCleaned && cleaned
        }
        return allCleaned
    }

    /// Drops one pairing's stored row and hidden marker so it fully disappears.
    ///
    /// Removes the durable row first (the only step that can fail): if it throws,
    /// the hidden marker is left intact so the forgotten computer stays hidden
    /// rather than resurfacing as a normal computer, and `false` is returned so the
    /// caller surfaces a retryable error instead of a silent partial cleanup. The
    /// marker is cleared only after the row is gone, so a still-online Mac that
    /// re-registers a fresh row is not re-hidden by a stale marker.
    private func removeStoredPairedMacRow(
        macDeviceID: String,
        instanceTag: String?,
        rowStackUserID: String,
        rowTeamID: String?,
        displayScope: MobileShellScopeSnapshot
    ) async -> Bool {
        if let pairedMacStore {
            do {
                // Delete the EXACT row scope, not `remove` (which re-resolves a
                // nil/team-less `teamID` to the currently-selected team) and not the
                // live display scope. `rowTeamID` is the row's OWN team (nil for a
                // team-less pairing); passing it verbatim deletes exactly the row the
                // user forgot. Using the display team here would miss a team-less row
                // shown under a selected team, or delete the wrong team's row after a
                // mid-revoke team switch.
                //
                // The backup tombstone follows the SAME scope: `upsert` stamps the
                // row and uploads its backup under one resolved team, so the row's
                // own `teamID` is the only client-side value tied to where the
                // backup lives. The display team is arbitrary for a team-less row
                // (it is shown under every selected team), so routing the tombstone
                // there would strand it in an unrelated team's backup — the row's
                // real backup would survive and restore the forgotten row, and a
                // same-device record in the displayed team could be wrongly deleted.
                try await pairedMacStore.removeExactScope(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    stackUserID: rowStackUserID,
                    teamID: rowTeamID
                )
            } catch {
                hiddenMacsLog.error(
                    "forget hidden computer row removal failed: \(String(describing: error), privacy: .private)"
                )
                return false
            }
        }
        // The hidden marker was keyed by the display scope when the row was hidden,
        // so clear it (and gate the on-screen refresh) against that scope.
        await clearHiddenMacDeviceID(
            macDeviceID,
            instanceTag: instanceTag,
            scope: displayScope
        )
        guard await isScopeCurrent(displayScope) else { return true }
        await loadPairedMacs()
        await loadRegistryDevices()
        // Mirror the hide path: once the last stored Mac is gone, drop the saved
        // reconnect hint so the app does not keep trying to redial a forgotten Mac.
        clearSavedMacHintWhenNoStoredMacsRemainIfNeeded()
        return true
    }

    /// Unhides one stored pairing immediately without requiring network access.
    public func unhideMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil
    ) async {
        guard let scope = await currentScopeSnapshot() else { return }
        await clearHiddenMacDeviceID(
            macDeviceID,
            instanceTag: instanceTag,
            scope: scope
        )
        guard await isScopeCurrent(scope) else { return }
        await loadPairedMacs()
        await loadRegistryDevices()
    }

    /// Hides the logical computer represented by a visible stored Mac id.
    public func hideMac(macDeviceID: String) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let macDeviceIDs = Array(Set(pairedMacAliasIDs(for: macDeviceID))).sorted()
        await hideStoredMacDeviceIDs(macDeviceIDs, scope: scope)
    }

    /// Hides one exact tagged app instance without hiding sibling instances.
    public func hideMac(macDeviceID: String, instanceTag: String?) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let targets = pairedMacsForIdentityMatching.filter {
            $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
        }
        guard !targets.isEmpty else { return }
        await hideStoredPairedMacs(targets, scope: scope)
    }

    /// Hides exactly one stored paired-Mac row.
    public func hideStoredMac(macDeviceID: String) async {
        guard let scope = await currentScopeSnapshot() else { return }
        await hideStoredMacDeviceIDs([macDeviceID], scope: scope)
    }

    /// Hides exactly one tagged stored pairing.
    public func hideStoredMac(macDeviceID: String, instanceTag: String?) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let targets = pairedMacsForIdentityMatching.filter {
            $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
        }
        guard !targets.isEmpty else { return }
        await hideStoredPairedMacs(targets, scope: scope)
    }

    func hideStoredMacDeviceIDs(
        _ macDeviceIDs: [String],
        scope: MobileShellScopeSnapshot
    ) async {
        guard !macDeviceIDs.isEmpty else { return }
        let targetIDSet = Set(macDeviceIDs)
        var targets = pairedMacsForIdentityMatching.filter {
            targetIDSet.contains($0.macDeviceID)
        }
        let foundPhysicalIDs = Set(targets.map(\.macDeviceID))
        for id in targetIDSet.subtracting(foundPhysicalIDs) {
            let identity = MobilePairedMac.pairingIdentity(from: id)
            let now = Date()
            targets.append(MobilePairedMac(
                macDeviceID: identity.macDeviceID,
                displayName: nil,
                routes: [],
                createdAt: now,
                lastSeenAt: now,
                isActive: false,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                instanceTag: identity.instanceTag
            ))
        }
        await hideStoredPairedMacs(targets, scope: scope)
    }

    private func hideStoredPairedMacs(
        _ targets: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) async {
        guard !targets.isEmpty else { return }
        let targetPairingIDs = Set(targets.map(\.id))
        let targetPhysicalIDs = Set(targets.map(\.macDeviceID))
        let teamlessLegacyIDs = Set(targets.filter { $0.teamID == nil }.map(\.id))
        for mac in targets {
            await rememberHiddenMacDeviceID(
                mac.id,
                scope: scope,
                includeUserWideScope: teamlessLegacyIDs.contains(mac.id)
            )
        }
        guard await isScopeCurrent(scope) else {
            for pairingID in targetPairingIDs {
                await clearHiddenMacDeviceID(pairingID, scope: scope)
            }
            return
        }

        invalidateStoredMacReconnectAttempt()
        let isActiveMac = targets.contains(where: \.isActive)
            || foregroundMacDeviceID.map(targetPhysicalIDs.contains) == true
        if isActiveMac {
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
        }

        let remainingPhysicalIDs = Set(pairedMacsForIdentityMatching
            .filter { !targetPairingIDs.contains($0.id) }
            .map(\.macDeviceID))
        let fullyHiddenPhysicalIDs = targetPhysicalIDs.subtracting(remainingPhysicalIDs)
        for id in fullyHiddenPhysicalIDs {
            if let subscription = secondaryMacSubscriptions[id] {
                subscription.cancel()
                secondaryMacSubscriptions[id] = nil
            }
            pruneWorkspaceStateForHiddenMac(id)
            removeNotificationFeedSnapshot(macDeviceID: id)
        }

        guard await isScopeCurrent(scope) else { return }
        await loadPairedMacs()
        clearSavedMacHintWhenNoStoredMacsRemainIfNeeded()
    }

    /// Removes every workspace snapshot owned by a hidden stored Mac.
    func pruneWorkspaceStateForHiddenMac(_ macDeviceID: String) {
        guard !macDeviceID.isEmpty else { return }
        if foregroundMacDeviceID == macDeviceID {
            foregroundMacDeviceID = nil
        }
        let pruned = workspacesByMac.reduce(into: [String: MacWorkspaceState]()) { result, entry in
            let (key, state) = entry
            guard key != macDeviceID, state.macDeviceID != macDeviceID else { return }
            let filteredWorkspaces = state.workspaces.filter { $0.macDeviceID != macDeviceID }
            var filteredState = state
            filteredState.workspaces = filteredWorkspaces
            result[key] = filteredState
        }
        if pruned != workspacesByMac {
            workspacesByMac = pruned
        }
    }

    func updateHiddenComputers(
        loadedMacs: [MobilePairedMac],
        hiddenIDs: Set<String>
    ) {
        let entries = loadedMacs.compactMap { mac -> MobileHiddenComputer? in
            guard hiddenIDs.contains(mac.id) || hiddenIDs.contains(mac.macDeviceID) else {
                return nil
            }
            return MobileHiddenComputer(
                id: mac.id,
                macDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                displayName: mac.resolvedName,
                customColor: mac.customColor,
                customIcon: mac.customIcon,
                stackUserID: mac.stackUserID,
                teamID: mac.teamID
            )
        }
        hiddenComputers = entries.sorted {
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        hasHiddenComputers = !hiddenComputers.isEmpty
    }
}
