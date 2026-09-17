import Bonsplit
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

    func titleStatusKey(from title: String) -> String? {
        let token = title.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
        guard let token else { return nil }
        return assetName(forStatusKey: token) == nil ? nil : token
    }
}

extension Workspace {
    /// Returns the current provider mark for one terminal panel, if known.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        let resolver = TerminalTabAgentIconResolver()
        let statusKeys = agentPIDKeysByPanelId[panelId, default: []]
            .map(agentStatusKey(forAgentPIDKey:))
            .sorted()
        if let asset = statusKeys.compactMap(resolver.assetName(forStatusKey:)).first {
            return asset
        }
        if let title = panels[panelId]?.displayTitle,
           let statusKey = resolver.titleStatusKey(from: title),
           let asset = resolver.assetName(forStatusKey: statusKey) {
            return asset
        }
        guard let restored = restoredAgentSnapshotsByPanelId[panelId] else { return nil }
        return restored.registration?.iconAssetName ?? resolver.assetName(forStatusKey: restored.kind.rawValue)
    }

    /// Reconciles a terminal tab's provider mark after agent lifecycle state changes.
    func syncTerminalTabAgentIconAsset(forPanelId panelId: UUID) {
        guard panels[panelId] is TerminalPanel,
              let tabID = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabID) else { return }
        let asset = terminalTabAgentIconAsset(forPanelId: panelId)
        guard tab.iconAsset != asset else { return }
        bonsplitController.updateTab(tabID, iconAsset: .some(asset))
    }
}
