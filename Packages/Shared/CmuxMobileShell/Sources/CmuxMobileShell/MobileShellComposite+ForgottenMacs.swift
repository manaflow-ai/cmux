import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
internal import OSLog

private let forgottenMacLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

@MainActor
extension MobileShellComposite {
    func storedForgottenMacDeviceIDs(scopeKey key: String) async -> Set<String> {
        if let cached = forgottenMacDeviceIDsByScope[key] { return cached }
        let loaded = await forgottenMacStore.load(scope: key)
        if let cached = forgottenMacDeviceIDsByScope[key] {
            return cached
        }
        forgottenMacDeviceIDsByScope[key] = loaded
        return loaded
    }

    func forgottenMacDeviceIDs(scope: MobileShellScopeSnapshot) async -> Set<String> {
        let key = pairedMacScopeKey(scope)
        let scoped = await storedForgottenMacDeviceIDs(scopeKey: key)
        guard scope.teamID != nil else { return scoped }
        let userWide = await storedForgottenMacDeviceIDs(scopeKey: pairedMacScopeKey(userWideScope(from: scope)))
        return scoped.union(userWide)
    }

    func visibleStoredPairedMacs(
        from loadedMacs: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) async -> [MobilePairedMac] {
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        return loadedMacs.filter {
            !forgottenIDs.contains($0.id) && !forgottenIDs.contains($0.macDeviceID)
        }
    }

    func isForgottenMacDeviceID(
        _ macDeviceID: String,
        instanceTag: String? = nil,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        let ids = await forgottenMacDeviceIDs(scope: scope)
        return ids.contains(macDeviceID) || ids.contains(MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ))
    }

    func removeStoredPairedMacIfForgotten(
        _ macDeviceID: String,
        instanceTag: String? = nil,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard await isForgottenMacDeviceID(
            macDeviceID,
            instanceTag: instanceTag,
            scope: scope
        ) else { return false }
        do {
            try await pairedMacStore?.remove(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                stackUserID: scope.userID,
                teamID: scope.teamID
            )
        } catch {
            forgottenMacLog.debug(
                "forgotten paired mac stale-row cleanup failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
        return true
    }

    func rememberForgottenMacDeviceID(
        _ macDeviceID: String,
        scope: MobileShellScopeSnapshot,
        includeUserWideScope: Bool = false
    ) async {
        guard !macDeviceID.isEmpty else { return }
        await rememberForgottenMacDeviceID(macDeviceID, scopeKey: pairedMacScopeKey(scope))
        if includeUserWideScope, scope.teamID != nil {
            await rememberForgottenMacDeviceID(macDeviceID, scopeKey: pairedMacScopeKey(userWideScope(from: scope)))
        }
        registryDevices.removeAll { $0.deviceId == macDeviceID }
    }

    func rememberForgottenMacDeviceID(_ macDeviceID: String, scopeKey key: String) async {
        var ids = await storedForgottenMacDeviceIDs(scopeKey: key)
        ids.insert(macDeviceID)
        forgottenMacDeviceIDsByScope[key] = ids
        await forgottenMacStore.save(ids, scope: key)
    }

    func clearForgottenMacDeviceID(
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
            await clearForgottenMacDeviceID(id, scopeKey: pairedMacScopeKey(scope))
        }
        if scope.teamID != nil {
            for id in ids {
                await clearForgottenMacDeviceID(
                    id,
                    scopeKey: pairedMacScopeKey(userWideScope(from: scope))
                )
            }
        }
    }

    func clearForgottenMacDeviceID(_ macDeviceID: String, scopeKey key: String) async {
        var ids = await storedForgottenMacDeviceIDs(scopeKey: key)
        guard ids.remove(macDeviceID) != nil else { return }
        forgottenMacDeviceIDsByScope[key] = ids
        await forgottenMacStore.save(ids, scope: key)
        if ids.isEmpty {
            forgottenMacDeviceIDsByScope[key] = nil
        }
    }

    /// Forget the logical computer represented by a stored Mac id.
    ///
    /// The Computers screen displays coalesced rows when multiple stored ids dial
    /// the same physical Mac. Deleting that row must remove every represented
    /// stored id, otherwise hidden aliases keep their workspace snapshots and the
    /// workspace list still looks too full after the user deletes a computer.
    /// - Parameter macDeviceID: A visible representative or hidden stored Mac id.
    public func forgetMac(macDeviceID: String) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let macDeviceIDs = Array(Set(pairedMacAliasIDs(for: macDeviceID))).sorted()
        await forgetStoredMacDeviceIDs(macDeviceIDs, scope: scope)
    }

    /// Forget one exact tagged app instance without removing sibling instances
    /// that share the same physical Mac device id.
    public func forgetMac(macDeviceID: String, instanceTag: String?) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let targets = pairedMacsForIdentityMatching.filter {
            $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
        }
        guard !targets.isEmpty else { return }
        await forgetStoredPairedMacs(targets, scope: scope)
    }

    /// Forget exactly one stored paired-Mac row.
    ///
    /// The host picker lists stored rows, not coalesced logical computers, and its
    /// swipe action has no confirmation. Keep that surface exact so a full-swipe
    /// cannot remove hidden alias rows that the user was not shown.
    public func forgetStoredMac(macDeviceID: String) async {
        guard let scope = await currentScopeSnapshot() else { return }
        await forgetStoredMacDeviceIDs([macDeviceID], scope: scope)
    }

    /// Forget exactly one tagged stored pairing.
    public func forgetStoredMac(macDeviceID: String, instanceTag: String?) async {
        guard let scope = await currentScopeSnapshot() else { return }
        let targets = pairedMacsForIdentityMatching.filter {
            $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
        }
        guard !targets.isEmpty else { return }
        await forgetStoredPairedMacs(targets, scope: scope)
    }

    func forgetStoredMacDeviceIDs(
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
            let now = Date()
            targets.append(MobilePairedMac(
                macDeviceID: id,
                displayName: nil,
                routes: [],
                createdAt: now,
                lastSeenAt: now,
                isActive: false,
                stackUserID: scope.userID,
                teamID: scope.teamID
            ))
        }
        await forgetStoredPairedMacs(targets, scope: scope)
    }

    private func forgetStoredPairedMacs(
        _ targets: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) async {
        guard !targets.isEmpty else { return }
        let targetPairingIDs = Set(targets.map(\.id))
        let targetPhysicalIDs = Set(targets.map(\.macDeviceID))
        let teamlessLegacyIDs = Set(targets.filter { $0.teamID == nil }.map(\.id))
        for mac in targets {
            await rememberForgottenMacDeviceID(
                mac.id,
                scope: scope,
                includeUserWideScope: teamlessLegacyIDs.contains(mac.id)
            )
        }
        guard await isScopeCurrent(scope) else {
            for pairingID in targetPairingIDs {
                await clearForgottenMacDeviceID(pairingID, scope: scope)
            }
            return
        }
        let workspacesBeforeForget = workspacesByMac
        let foregroundMacDeviceIDBeforeForget = foregroundMacDeviceID
        let isActiveMac = targets.contains(where: \.isActive)
        if !targets.isEmpty {
            invalidateStoredMacReconnectAttempt()
        }
        if isActiveMac {
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
        }
        let remainingPhysicalIDs = Set(pairedMacsForIdentityMatching
            .filter { !targetPairingIDs.contains($0.id) }
            .map(\.macDeviceID))
        let fullyRemovedPhysicalIDs = targetPhysicalIDs.subtracting(remainingPhysicalIDs)
        for id in fullyRemovedPhysicalIDs {
            if let subscription = secondaryMacSubscriptions[id] {
                subscription.cancel()
                secondaryMacSubscriptions[id] = nil
            }
            pruneWorkspaceStateForForgottenMac(id)
        }
        guard await isScopeCurrent(scope) else {
            for pairingID in targetPairingIDs {
                await clearForgottenMacDeviceID(pairingID, scope: scope)
            }
            workspacesByMac = workspacesBeforeForget
            foregroundMacDeviceID = foregroundMacDeviceIDBeforeForget
            return
        }
        var removedPairingIDs = Set<String>()
        var failedPairingIDs = Set<String>()
        for mac in targets {
            do {
                try await pairedMacStore?.remove(
                    macDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
                removedPairingIDs.insert(mac.id)
            } catch {
                failedPairingIDs.insert(mac.id)
                forgottenMacLog.error("paired mac store remove failed mac=\(mac.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
        guard await isScopeCurrent(scope) else { return }
        if !failedPairingIDs.isEmpty {
            for pairingID in failedPairingIDs {
                await clearForgottenMacDeviceID(pairingID, scope: scope)
            }
            workspacesByMac = workspacesBeforeForget
            foregroundMacDeviceID = foregroundMacDeviceIDBeforeForget
            let removedPhysicalIDs = Set(targets
                .filter { removedPairingIDs.contains($0.id) }
                .map(\.macDeviceID))
                .subtracting(remainingPhysicalIDs)
            for id in removedPhysicalIDs {
                pruneWorkspaceStateForForgottenMac(id)
            }
        }
        await loadPairedMacs()
        clearSavedMacHintAfterDeletingLastVisibleMacIfNeeded()
    }

    /// Remove every workspace snapshot owned by a forgotten stored Mac.
    ///
    /// Most per-Mac snapshots are keyed by the Mac's real device id, but older
    /// manual/anonymous foreground attaches can keep the snapshot under
    /// ``foregroundAnonymousKey`` while its rows are already stamped with the
    /// real `macDeviceID`. Deleting the computer must clear both shapes so the
    /// workspace list cannot keep routing taps into a removed Mac.
    func pruneWorkspaceStateForForgottenMac(_ macDeviceID: String) {
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
        if pruned.count != workspacesByMac.count {
            workspacesByMac = pruned
        } else if pruned != workspacesByMac {
            workspacesByMac = pruned
        }
    }
}
