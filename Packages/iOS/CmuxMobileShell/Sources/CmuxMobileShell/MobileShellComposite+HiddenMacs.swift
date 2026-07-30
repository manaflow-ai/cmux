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
        return await removeStoredPairedMacRow(
            macDeviceID: computer.macDeviceID,
            instanceTag: computer.instanceTag,
            rowStackUserID: computer.stackUserID ?? scope.userID,
            rowTeamID: computer.teamID,
            displayScope: scope
        )
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
                // The server backup, however, lives in a per-team Durable Object, so
                // a team-less row's tombstone must route to the team it was DISPLAYED
                // under (`displayScope.teamID`), captured before the revoke. Reusing
                // the nil local team for the backup would let the server resolve the
                // delete to whatever team is selected at flush time and wipe a
                // same-device record from the wrong team's backup.
                try await pairedMacStore.removeExactScope(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    stackUserID: rowStackUserID,
                    teamID: rowTeamID,
                    backupTeamID: displayScope.teamID
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

    /// Hides the legacy untagged computer represented by a visible stored Mac id.
    ///
    /// Tagged row actions must use
    /// ``hideStoredPairedMacEntries(representativeID:aliasIDs:)`` so a physical
    /// Mac's sibling app instances remain visible.
    public func hideMac(macDeviceID: String) async {
        await hideStoredPairedMacEntries(
            representativeID: MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: nil
            ),
            aliasIDs: pairedMacAliasIDs(for: macDeviceID)
        )
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

    /// Hides the stored pairing entries represented by one visible computer row.
    ///
    /// Raw device IDs in `aliasIDs` inherit the representative's instance tag
    /// before matching, while already-composite pairing IDs retain their embedded
    /// tag. Targets are then selected by exact ``MobilePairedMac/id`` equality.
    /// - Parameters:
    ///   - representativeID: The visible row's composite pairing ID.
    ///   - aliasIDs: Stored IDs coalesced into that row. An empty array falls
    ///     back to `representativeID`.
    public func hideStoredPairedMacEntries(
        representativeID: String,
        aliasIDs: [String]
    ) async {
        guard !representativeID.isEmpty,
              let scope = await currentScopeSnapshot() else { return }
        let representative = MobilePairedMac.pairingIdentity(from: representativeID)
        let targetPairingIDs: Set<String> = Set(
            ([representativeID] + aliasIDs).compactMap { storedID in
                guard !storedID.isEmpty else { return nil }
                let identity = MobilePairedMac.pairingIdentity(from: storedID)
                return MobilePairedMac.pairingID(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: identity.instanceTag ?? representative.instanceTag
                )
            }
        )
        let targets = pairedMacsForIdentityMatching.filter {
            targetPairingIDs.contains($0.id)
        }
        guard !targets.isEmpty else { return }
        await hideStoredPairedMacs(targets, scope: scope)
    }

    /// Hides exactly one stored paired-Mac row.
    public func hideStoredMac(macDeviceID: String) async {
        await hideStoredPairedMacEntries(
            representativeID: MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: nil
            ),
            aliasIDs: [macDeviceID]
        )
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
        let foregroundPairingID = foregroundMacDeviceID.map {
            MobilePairedMac.pairingID(
                macDeviceID: $0,
                instanceTag: connectedMacInstanceTag
            )
        }
        let isActiveMac = targets.contains(where: \.isActive)
            || foregroundPairingID.map(targetPairingIDs.contains) == true
        if isActiveMac {
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
        }

        let remainingPhysicalIDs = Set(pairedMacsForIdentityMatching
            .filter { !targetPairingIDs.contains($0.id) }
            .map(\.macDeviceID))
        // Workspace state is keyed by PHYSICAL device id, so it is shared by
        // every app instance of a Mac. Prune it only when no visible sibling
        // instance remains; a per-instance hide leaves the sibling's state.
        // Subscriptions, per-pairing workspace entries, and feed snapshots are
        // keyed per pairing since the per-pairing re-key: tear down exactly the
        // hidden pairings' entries, whether or not a sibling remains visible.
        for pairingID in targetPairingIDs {
            if let subscription = secondaryMacSubscriptions[pairingID] {
                subscription.cancel()
                secondaryMacSubscriptions[pairingID] = nil
            }
            workspacesByMac[pairingID] = nil
            removeNotificationFeedSnapshot(macDeviceID: pairingID)
        }
        // The foreground pairing's feed snapshot AND workspace entry live under
        // the bare DEVICE key. Hiding it while a sibling pairing stays visible
        // skips the fully-hidden prune below, so remove both explicitly —
        // matching the retained state's tag so a sibling's entry is preserved.
        if let foregroundPairingID, targetPairingIDs.contains(foregroundPairingID) {
            let identity = MobilePairedMac.pairingIdentity(from: foregroundPairingID)
            removeNotificationFeedSnapshot(macDeviceID: identity.macDeviceID)
            if let retained = workspacesByMac[identity.macDeviceID],
               macInstanceTagAuthority.sameStoredAuthority(
                   retained.instanceTag, identity.instanceTag
               ) {
                workspacesByMac[identity.macDeviceID] = nil
            }
        }
        let fullyHiddenPhysicalIDs = targetPhysicalIDs.subtracting(remainingPhysicalIDs)
        for id in fullyHiddenPhysicalIDs {
            pruneWorkspaceStateForHiddenMac(id)
            removeNotificationFeedSnapshot(macDeviceID: id)
        }

        guard await isScopeCurrent(scope) else { return }
        await loadPairedMacs()
        clearSavedMacHintWhenNoStoredMacsRemainIfNeeded()
    }

    /// Removes every workspace snapshot owned by a hidden stored Mac identity.
    func pruneWorkspaceStateForHiddenMac(_ storedMacID: String) {
        guard !storedMacID.isEmpty else { return }
        if foregroundMacDeviceID == storedMacID {
            foregroundMacDeviceID = nil
        }
        let pruned = workspacesByMac.reduce(into: [String: MacWorkspaceState]()) { result, entry in
            let (key, state) = entry
            guard key != storedMacID, state.macDeviceID != storedMacID else { return }
            let filteredWorkspaces = state.workspaces.filter { $0.macDeviceID != storedMacID }
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
