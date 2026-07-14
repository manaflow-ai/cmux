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
    func pendingForgottenMacDeviceIDs(scope: MobileShellScopeSnapshot) -> Set<String> {
        let scopedKey = pairedMacScopeKey(scope)
        var pending = forgottenMacIntentDeviceIDsByScope[scopedKey] ?? []
        if scope.teamID != nil {
            let userWideKey = pairedMacScopeKey(userWideScope(from: scope))
            pending.formUnion(forgottenMacIntentDeviceIDsByScope[userWideKey] ?? [])
        }
        return pending
    }

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
            .union(forgottenMacIntentDeviceIDsByScope[key] ?? [])
        guard scope.teamID != nil else { return scoped }
        let userWideKey = pairedMacScopeKey(userWideScope(from: scope))
        let userWide = await storedForgottenMacDeviceIDs(scopeKey: userWideKey)
            .union(forgottenMacIntentDeviceIDsByScope[userWideKey] ?? [])
        return scoped.union(userWide)
    }

    func visibleStoredPairedMacs(
        from loadedMacs: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) async -> [MobilePairedMac] {
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        return loadedMacs.filter { !forgottenIDs.contains($0.macDeviceID) }
    }

    func isForgottenMacDeviceID(_ macDeviceID: String, scope: MobileShellScopeSnapshot) async -> Bool {
        let scopedKey = pairedMacScopeKey(scope)
        if forgottenMacIntentDeviceIDsByScope[scopedKey]?.contains(macDeviceID) == true {
            return true
        }
        if scope.teamID != nil {
            let userWideKey = pairedMacScopeKey(userWideScope(from: scope))
            if forgottenMacIntentDeviceIDsByScope[userWideKey]?.contains(macDeviceID) == true {
                return true
            }
        }
        return await forgottenMacDeviceIDs(scope: scope).contains(macDeviceID)
    }

    func removeStoredPairedMacIfForgotten(
        _ macDeviceID: String,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard await isForgottenMacDeviceID(macDeviceID, scope: scope) else { return false }
        do {
            try await pairedMacStore?.remove(
                macDeviceID: macDeviceID,
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
        var intents = forgottenMacIntentDeviceIDsByScope[key] ?? []
        intents.insert(macDeviceID)
        forgottenMacIntentDeviceIDsByScope[key] = intents
        var ids = await storedForgottenMacDeviceIDs(scopeKey: key)
        guard forgottenMacIntentDeviceIDsByScope[key]?.contains(macDeviceID) == true else {
            return
        }
        ids.insert(macDeviceID)
        forgottenMacDeviceIDsByScope[key] = ids
        await forgottenMacStore.save(ids, scope: key)
    }

    func clearForgottenMacDeviceID(_ macDeviceID: String, scope: MobileShellScopeSnapshot?) async {
        guard !macDeviceID.isEmpty, let scope else { return }
        await clearForgottenMacDeviceID(macDeviceID, scopeKey: pairedMacScopeKey(scope))
        if scope.teamID != nil {
            await clearForgottenMacDeviceID(macDeviceID, scopeKey: pairedMacScopeKey(userWideScope(from: scope)))
        }
    }

    func clearForgottenMacDeviceID(_ macDeviceID: String, scopeKey key: String) async {
        var intents = forgottenMacIntentDeviceIDsByScope[key] ?? []
        intents.remove(macDeviceID)
        forgottenMacIntentDeviceIDsByScope[key] = intents.isEmpty ? nil : intents
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

    /// Forget exactly one stored paired-Mac row.
    ///
    /// The host picker lists stored rows, not coalesced logical computers, and its
    /// swipe action has no confirmation. Keep that surface exact so a full-swipe
    /// cannot remove hidden alias rows that the user was not shown.
    public func forgetStoredMac(macDeviceID: String) async {
        guard let scope = await currentScopeSnapshot() else { return }
        await forgetStoredMacDeviceIDs([macDeviceID], scope: scope)
    }

    func forgetStoredMacDeviceIDs(
        _ macDeviceIDs: [String],
        scope: MobileShellScopeSnapshot
    ) async {
        guard !macDeviceIDs.isEmpty else { return }
        let targetIDSet = Set(macDeviceIDs)
        invalidateDeferredCachedReconnectPersistence(forgetting: targetIDSet)
        let forgetsReconnectTarget = connectionLifecycle.activeEpisode?.kind == .reconnect
            && storedMacReconnectTargetDeviceID.map(targetIDSet.contains) == true
        let forgetsKnownMac = pairedMacsForIdentityMatching.contains {
            targetIDSet.contains($0.macDeviceID)
        }
        if forgetsReconnectTarget {
            connectionLifecycleTaskOwnership.activeReconnectProgress?.markForgotten(targetIDSet)
            // Revoke reconnect ownership before the first suspension. A store or
            // tombstone write may ignore task cancellation, so generation checks
            // must already fail when that stale work resumes.
            resetConnectionLifecycle()
        } else if forgetsKnownMac {
            invalidateStoredMacReconnectAttempt()
        }
        connectionLifecycleTaskOwnership.clearRetiredReconnectDemand(
            forgetting: targetIDSet
        )
        if !connectionLifecycleTaskOwnership.retiredCarriesReconnectDemand {
            connectionLifecycleReconnectPendingAfterRetirement = false
        }
        let teamlessLegacyIDs = Set(pairedMacsForIdentityMatching
            .filter { targetIDSet.contains($0.macDeviceID) && $0.teamID == nil }
            .map(\.macDeviceID))
        for id in macDeviceIDs {
            await rememberForgottenMacDeviceID(
                id,
                scope: scope,
                includeUserWideScope: teamlessLegacyIDs.contains(id)
            )
        }
        guard await isScopeCurrent(scope) else {
            for id in macDeviceIDs {
                await clearForgottenMacDeviceID(id, scope: scope)
            }
            return
        }
        let workspacesBeforeForget = workspacesByMac
        let foregroundMacDeviceIDBeforeForget = foregroundMacDeviceID
        let isActiveMac = pairedMacsForIdentityMatching.contains {
            targetIDSet.contains($0.macDeviceID) && $0.isActive
        }
        let isLiveForegroundMac = connectionState == .connected
            && foregroundMacDeviceID.map(targetIDSet.contains) == true
        if isActiveMac || isLiveForegroundMac {
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
        }
        for id in macDeviceIDs {
            if let subscription = secondaryMacSubscriptions[id] {
                subscription.cancel()
                secondaryMacSubscriptions[id] = nil
            }
            pruneWorkspaceStateForForgottenMac(id)
        }
        guard await isScopeCurrent(scope) else {
            for id in macDeviceIDs {
                await clearForgottenMacDeviceID(id, scope: scope)
            }
            workspacesByMac = workspacesBeforeForget
            foregroundMacDeviceID = foregroundMacDeviceIDBeforeForget
            return
        }
        var removedIDs = Set<String>()
        var failedIDs = Set<String>()
        for id in macDeviceIDs {
            do {
                try await pairedMacStore?.remove(
                    macDeviceID: id,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
                removedIDs.insert(id)
            } catch {
                failedIDs.insert(id)
                forgottenMacLog.error("paired mac store remove failed mac=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
        guard await isScopeCurrent(scope) else { return }
        if !failedIDs.isEmpty {
            for id in failedIDs {
                await clearForgottenMacDeviceID(id, scope: scope)
            }
            workspacesByMac = workspacesBeforeForget
            foregroundMacDeviceID = foregroundMacDeviceIDBeforeForget
            for id in removedIDs {
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
