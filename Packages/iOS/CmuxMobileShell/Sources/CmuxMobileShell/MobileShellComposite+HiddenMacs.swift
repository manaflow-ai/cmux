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
            try await personalIrohForget.forgetComputer(
                macDeviceID: computer.macDeviceID,
                instanceTag: computer.instanceTag,
                expectedAccountID: scope.userID
            )
        } catch {
            hiddenMacsLog.error(
                "forget hidden computer revoke failed: \(String(describing: error), privacy: .private)"
            )
            return false
        }
        // Always clear the captured scope's durable row and hidden marker, even if
        // the scope changed while the revoke was in flight: `removeStoredPairedMacRow`
        // removes against the CAPTURED scope (not the current one), so it cannot
        // touch another account's data, and it internally gates only the on-screen
        // refresh on the scope still being current. Skipping it here would report
        // success while leaving the row behind, so returning to the old scope would
        // show the supposedly forgotten computer.
        return await removeStoredPairedMacRow(
            macDeviceID: computer.macDeviceID,
            instanceTag: computer.instanceTag,
            scope: scope
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
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        if let pairedMacStore {
            do {
                try await pairedMacStore.remove(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            } catch {
                hiddenMacsLog.error(
                    "forget hidden computer row removal failed: \(String(describing: error), privacy: .private)"
                )
                return false
            }
        }
        await clearHiddenMacDeviceID(
            macDeviceID,
            instanceTag: instanceTag,
            scope: scope
        )
        guard await isScopeCurrent(scope) else { return true }
        await loadPairedMacs()
        await loadRegistryDevices()
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
                customIcon: mac.customIcon
            )
        }
        hiddenComputers = entries.sorted {
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        hasHiddenComputers = !hiddenComputers.isEmpty
    }
}
