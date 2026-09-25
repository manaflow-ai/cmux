import Bonsplit
import Foundation

/// Resolves a provider mark from the same agent
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
    /// Returns the provider mark for a Cloud terminal tab. The agent runs on
    /// the remote machine, so its projected resource is the owner. Local
    /// terminal tabs keep the plain terminal icon.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        guard let remote = cloudProjectedResource(forPanel: panelId), remote.kind == .terminal else { return nil }
        return remote.terminalAgentIconAssetName
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
