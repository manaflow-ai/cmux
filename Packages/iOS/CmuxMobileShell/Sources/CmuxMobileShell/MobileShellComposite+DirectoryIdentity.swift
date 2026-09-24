import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// Directory identities own connection eligibility in v2. Saved rows own
    /// preferences and are reconciled before selection, hidden filtering or dial.
    /// nil retains the behavior of legacy/test discovery adapters.
    func refreshDirectoryPairedMacIdentities(scope: MobileShellScopeSnapshot) async throws -> Set<String>? {
        guard let discovery = personalIrohDiscovery, discovery.usesAuthoritativeDeviceIDs else { return nil }
        let discovered = await discovery.discoverLiveMacs()
        guard await isScopeCurrent(scope) else { throw CancellationError() }
        try await reconcileDirectoryPairedMacIdentities(discovered, scope: scope)
        guard await isScopeCurrent(scope) else { throw CancellationError() }
        return Set(discovered.map {
            MobilePairedMac.pairingID(macDeviceID: $0.deviceID, instanceTag: $0.instanceTag)
        })
    }

    func reconcileDirectoryPairedMacIdentities(
        _ discovered: [MobileDiscoveredIrohMac],
        scope: MobileShellScopeSnapshot
    ) async throws {
        guard personalIrohDiscovery?.usesAuthoritativeDeviceIDs == true,
              let legacyMacIdentityMigration else { return }
        guard await isScopeCurrent(scope) else { throw CancellationError() }
        let evidence = discovered.map {
            MobilePairedMacDirectoryIdentity(deviceID: $0.deviceID, instanceTag: $0.instanceTag, routes: $0.routes)
        }
        let replacements = try await legacyMacIdentityMigration.reconcileLegacyIdentities(
            with: evidence, stackUserID: scope.userID, teamID: scope.teamID
        )
        guard await isScopeCurrent(scope) else { throw CancellationError() }
        guard !replacements.isEmpty else { return }
        // SQL commits the mapping first. Every later pass replays it so a crash
        // before UserDefaults is saved cannot turn a hidden computer back on.
        var scopes = [pairedMacScopeKey(scope)]
        if scope.teamID != nil { scopes.append(pairedMacScopeKey(userWideScope(from: scope))) }
        for key in scopes {
            var hidden = await storedHiddenMacDeviceIDs(scopeKey: key)
            guard await isScopeCurrent(scope) else { throw CancellationError() }
            let before = hidden
            for replacement in replacements where hidden.contains(replacement.oldPairingID) {
                hidden.insert(replacement.newPairingID)
                hidden.remove(replacement.oldPairingID)
            }
            if hidden != before {
                hiddenMacDeviceIDsByScope[key] = hidden
                await hiddenMacStore.save(hidden, scope: key)
            }
        }
        guard await isScopeCurrent(scope) else { throw CancellationError() }
        let aliases = Dictionary(replacements.map { ($0.oldPairingID, $0.newPairingID) },
                                 uniquingKeysWith: { first, _ in first })
        var priority: [String] = []
        for old in workspaceComputerPriority {
            let current = aliases[old] ?? old
            if !priority.contains(current) { priority.append(current) }
        }
        if priority != workspaceComputerPriority {
            workspaceSortStore.setComputerPriority(priority)
            workspaceComputerPriority = priority
        }
    }

    /// Final shared gate for stored foreground and secondary attempts. A local
    /// record never grants v2 identity authority, including manual selection.
    func directoryAllowsConnection(macDeviceID: String, instanceTag: String?) async -> Bool {
        guard let discovery = personalIrohDiscovery, discovery.usesAuthoritativeDeviceIDs else { return true }
        guard let scope = await currentScopeSnapshot() else { return false }
        let discovered = await discovery.discoverLiveMacs()
        guard await isScopeCurrent(scope) else { return false }
        let wanted = MobilePairedMac.pairingID(macDeviceID: macDeviceID, instanceTag: instanceTag)
        return discovered.contains {
            MobilePairedMac.pairingID(macDeviceID: $0.deviceID, instanceTag: $0.instanceTag) == wanted
        }
    }
}
