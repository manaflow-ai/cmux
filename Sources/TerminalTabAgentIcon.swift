import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

/// Resolves the provider mark for a local terminal tab from the same agent
/// definitions used by process and hook detection.
struct TerminalTabAgentIconResolver {
    func assetName(forStatusKey statusKey: String) -> String? {
        let normalized = statusKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first { definition in
            definition.id == normalized
                || definition.launchKinds.contains(normalized)
                || definition.directBasenames.contains(normalized)
        }?.assetName
    }
}

extension Workspace {
    /// Returns the current provider mark for one terminal panel, if known.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        let resolver = TerminalTabAgentIconResolver()
        let pidStatusKeys = agentPIDKeysByPanelId[panelId, default: []]
            .map(agentStatusKey(forAgentPIDKey:))
        let lifecycleStates = agentLifecycleStatesByPanelId[panelId, default: [:]]
        // Lifecycle maps may contain custom keys, but only the fixed built-in
        // IDs and aliases can resolve to a tab asset. Look those keys up
        // directly instead of scanning the whole map on every lifecycle event.
        let lifecycleStatusKeys = CmuxTaskManagerCodingAgentDefinition.builtIns
            .flatMap { definition -> [String] in
                let knownKeys = [definition.id] + definition.launchKinds + definition.directBasenames
                return knownKeys.compactMap { key in
                    if lifecycleStates[key] != nil { return key }
                    let remoteKey = RemoteAgentSidebarStatus.statusKeyPrefix + key
                    if lifecycleStates[remoteKey] != nil { return key }
                    let attentionKey = "cmux.feed.attention:" + key
                    return lifecycleStates[attentionKey] != nil ? key : nil
                }
            }
        let statusKeys = Set(pidStatusKeys).union(lifecycleStatusKeys).sorted()
        if let asset = statusKeys.compactMap(resolver.assetName(forStatusKey:)).first {
            return asset
        }
        // A restored snapshot outlives its agent (completed sessions stay for
        // history), so it only names the tab while that agent is running.
        guard let restored = restoredAgentSnapshotsByPanelId[panelId],
              restoredAgentIsRunning(panelId: panelId) else { return nil }
        return restored.registration?.iconAssetName ?? resolver.assetName(forStatusKey: restored.kind.rawValue)
    }

    private func restoredAgentIsRunning(panelId: UUID) -> Bool {
        switch restoredAgentResumeStatesByPanelId[panelId] {
        case .autoResumeCommandRunning, .observedAgentCommandRunning:
            return true
        case .manualResumeAvailable, .awaitingAutoResumeCommand, .completedAgentExit, nil:
            return false
        }
    }

    /// Reconciles a terminal tab's provider mark after agent lifecycle state changes.
    func syncTerminalTabAgentIconAsset(forPanelId panelId: UUID) {
        // Remote workspaces receive their authoritative icon from SurfaceCatalog;
        // local lifecycle updates must not overwrite that projection.
        guard !isRemoteWorkspace,
              SurfaceCatalog.shared.machineOwningPanel(panelId)?.isLocal != false,
              panels[panelId] is TerminalPanel,
              let tabID = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabID) else { return }
        let asset = terminalTabAgentIconAsset(forPanelId: panelId)
        guard tab.iconAsset != asset else { return }
        bonsplitController.updateTab(tabID, iconAsset: .some(asset))
    }
}
