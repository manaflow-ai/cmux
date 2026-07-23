import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation

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
        return loadedMacs.filter {
            !hiddenIDs.contains($0.id) && !hiddenIDs.contains($0.macDeviceID)
        }
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

    /// Removes one dead legacy hidden marker from this iPhone without reviving its Mac.
    ///
    /// Normal hidden entries retain a local paired-Mac row and must use
    /// ``unhideMacDeviceID(_:instanceTag:)`` instead.
    /// - Parameter computer: The legacy hidden entry whose local markers should be discarded.
    public func discardLegacyHiddenComputer(_ computer: MobileHiddenComputer) async {
        guard computer.requiresLegacyRecovery,
              let scope = await currentScopeSnapshot() else { return }
        // This is local marker cleanup only: any server tombstone remains, and
        // explicit QR pairing can still recreate the Mac later.
        await clearHiddenMacDeviceID(
            computer.macDeviceID,
            instanceTag: computer.instanceTag,
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
        var matchedIDs: Set<String> = []
        var entries = loadedMacs.compactMap { mac -> MobileHiddenComputer? in
            guard hiddenIDs.contains(mac.id) || hiddenIDs.contains(mac.macDeviceID) else {
                return nil
            }
            matchedIDs.insert(mac.id)
            matchedIDs.insert(mac.macDeviceID)
            return MobileHiddenComputer(
                id: mac.id,
                macDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                displayName: mac.resolvedName,
                customColor: mac.customColor,
                customIcon: mac.customIcon,
                requiresLegacyRecovery: false
            )
        }
        for hiddenID in hiddenIDs where !matchedIDs.contains(hiddenID) {
            let identity = MobilePairedMac.pairingIdentity(from: hiddenID)
            let registryName = hiddenRegistryDisplayNamesByDeviceID[identity.macDeviceID]
            entries.append(MobileHiddenComputer(
                id: hiddenID,
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag,
                displayName: registryName ?? Self.shortenedHiddenMacID(identity.macDeviceID),
                customColor: nil,
                customIcon: nil,
                requiresLegacyRecovery: true
            ))
        }
        hiddenComputers = entries.sorted {
            if $0.requiresLegacyRecovery != $1.requiresLegacyRecovery {
                return !$0.requiresLegacyRecovery
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        hasHiddenComputers = !hiddenComputers.isEmpty
    }

    private static func shortenedHiddenMacID(_ id: String) -> String {
        guard id.count > 16 else { return id }
        return "\(id.prefix(8))…\(id.suffix(4))"
    }
}
