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
        // Always clear the durable row(s) and hidden marker, even if the scope
        // changed while the revoke was in flight. Every row is deleted against
        // ITS OWN stored scope, never the live display scope: a team-less row
        // is visible under any selected team (legacy visibility), so deleting
        // with the display team would miss it and it would resurface once the
        // marker cleared. For a tag-less row the revoke above was the
        // device-wide wildcard (every tag of this device, for the pinned
        // account), so cleanup matches that breadth: every account-owned row of
        // the device, across teams, in ONE batched store call whose backup
        // tombstones flush once per destination — per-row deletion would issue
        // one sequential backup request per row, and a device can carry up to
        // the discovery snapshot's 256 bindings. Rows owned by other accounts
        // keep their bindings (the revoke was account-pinned) and stay.
        let cleaned = await deleteStoredPairedMacRows(
            for: computer,
            pinnedAccountID: computer.stackUserID ?? scope.userID,
            displayScope: scope
        )
        // ONE refresh for the whole cleanup. Refreshing per deleted row re-runs
        // the paired list load (and with it the backup restore fetch) and the
        // registry fetch for every sibling.
        await refreshAfterForget(displayScope: scope)
        return cleaned
    }

    /// The single post-forget refresh: reload the paired list and registry and
    /// drop the saved reconnect hint once the last stored Mac is gone. Skipped
    /// when the display scope changed mid-forget (the new scope's own loads
    /// already reflect its stores).
    private func refreshAfterForget(displayScope: MobileShellScopeSnapshot) async {
        guard await isScopeCurrent(displayScope) else { return }
        await loadPairedMacs()
        await loadRegistryDevices()
        // Mirror the hide path: once the last stored Mac is gone, drop the saved
        // reconnect hint so the app does not keep trying to redial a forgotten Mac.
        clearSavedMacHintWhenNoStoredMacsRemainIfNeeded()
    }

    /// Deletes every row a forget covers — the exact forgotten row, plus (for a
    /// tag-less wildcard forget) every account-owned instance of the device
    /// across teams — as ONE batched store call, then clears their hidden
    /// markers.
    ///
    /// The wildcard revoke kills the device's bindings for the WHOLE account,
    /// across teams — an offline Mac never re-registers, so any row left behind
    /// (in another team, or another tag) makes the supposedly forgotten
    /// computer reappear when the user switches teams or restores. Enumeration
    /// uses the cross-team `loadAllInstances` (the ordinary team-scoped read
    /// cannot see past the display team); an enumeration FAILURE is a cleanup
    /// failure — the revoke already succeeded account-wide, so silently
    /// claiming success would leave dead rows whose bindings are gone. Rows
    /// owned by other accounts still hold live bindings and must survive.
    /// Markers are cleared only after the batch succeeds, so a failed cleanup
    /// keeps the computer hidden and retryable rather than resurfacing it.
    private func deleteStoredPairedMacRows(
        for computer: MobileHiddenComputer,
        pinnedAccountID: String,
        displayScope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard let pairedMacStore else {
            await clearHiddenMacDeviceID(
                computer.macDeviceID,
                instanceTag: computer.instanceTag,
                scope: displayScope
            )
            return true
        }
        let primary = MobilePairedMacExactScope(
            macDeviceID: computer.macDeviceID,
            instanceTag: computer.instanceTag,
            stackUserID: pinnedAccountID,
            teamID: computer.teamID
        )
        var scopes = [primary]
        // Cross-team sibling cleanup runs for EVERY forget: the broker binding
        // is account-wide, so revoking it kills the binding every team's copy
        // of the pairing uses. A tagged forget revoked exactly the (device,
        // tag) binding — other teams' SAME-TAG rows are dead, different-tag
        // rows keep their own live bindings and survive. A tag-less forget's
        // wildcard revoke covered every tag, so its cleanup does too.
        let rows: [MobilePairedMac]
        do {
            rows = try await pairedMacStore.loadAllInstances(
                macDeviceID: computer.macDeviceID,
                stackUserID: pinnedAccountID
            )
        } catch {
            hiddenMacsLog.error(
                "forget hidden computer sibling enumeration failed: \(String(describing: error), privacy: .private)"
            )
            return false
        }
        for row in rows
        where row.stackUserID == pinnedAccountID
            && (computer.instanceTag == nil || row.instanceTag == computer.instanceTag)
            && !(row.instanceTag == primary.instanceTag && row.teamID == primary.teamID) {
            scopes.append(MobilePairedMacExactScope(
                macDeviceID: row.macDeviceID,
                instanceTag: row.instanceTag,
                stackUserID: pinnedAccountID,
                teamID: row.teamID
            ))
        }
        do {
            try await pairedMacStore.removeExactScopes(scopes)
        } catch {
            hiddenMacsLog.error(
                "forget hidden computer row removal failed: \(String(describing: error), privacy: .private)"
            )
            return false
        }
        // The hidden markers were keyed by the display scope when the rows were
        // hidden, so clear them against that scope — only after the rows are
        // gone, so a still-online Mac that re-registers is not re-hidden by a
        // stale marker.
        for scope in scopes {
            await clearHiddenMacDeviceID(
                scope.macDeviceID,
                instanceTag: scope.instanceTag,
                scope: displayScope
            )
        }
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
