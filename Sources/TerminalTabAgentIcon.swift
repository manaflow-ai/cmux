import Bonsplit
import Foundation

struct TerminalTabAgentIconResolver {
    func assetName(liveStatusKeys: Set<String>, restoredAgentKind: String?) -> String? {
        if let liveAsset = liveStatusKeys.sorted().compactMap(assetName(statusKey:)).first {
            return liveAsset
        }
        guard let restoredAgentKind else { return nil }
        return assetName(statusKey: restoredAgentKind)
    }

    func assetName(agentPIDKeys: Set<String>, restoredAgentKind: String?) -> String? {
        assetName(
            liveStatusKeys: Set(agentPIDKeys.map(statusKey(forAgentPIDKey:))),
            restoredAgentKind: restoredAgentKind
        )
    }

    private func statusKey(forAgentPIDKey key: String) -> String {
        key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? key
    }

    private func assetName(statusKey: String) -> String? {
        switch statusKey {
        case "claude", "claude_code":
            return "AgentIcons/Claude"
        case "codex":
            return "AgentIcons/Codex"
        case "opencode":
            return "AgentIcons/OpenCode"
        case "pi", "omp":
            return "AgentIcons/Pi"
        case "grok":
            return "AgentIcons/Grok"
        case "rovodev":
            return "AgentIcons/RovoDev"
        case "antigravity":
            return "AgentIcons/Antigravity"
        case "hermes-agent":
            return "AgentIcons/HermesAgent"
        default:
            return nil
        }
    }
}

extension Workspace {
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        let liveStatusKeys = Set((agentPIDKeysByPanelId[panelId] ?? []).map(agentStatusKey(forAgentPIDKey:)))
        return TerminalTabAgentIconResolver().assetName(
            liveStatusKeys: liveStatusKeys,
            restoredAgentKind: restoredAgentSnapshotsByPanelId[panelId]?.kind.rawValue
        )
    }

    func syncTerminalTabAgentIconAsset(forPanelId panelId: UUID) {
        guard panels[panelId] is TerminalPanel,
              let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId) else {
            return
        }
        let iconAsset = terminalTabAgentIconAsset(forPanelId: panelId)
        guard existing.iconAsset != iconAsset else { return }
        bonsplitController.updateTab(tabId, iconAsset: .some(iconAsset))
    }

    func syncTerminalTabAgentIconAssetsForAllTerminalPanels() {
        for (panelId, panel) in panels where panel is TerminalPanel {
            syncTerminalTabAgentIconAsset(forPanelId: panelId)
        }
    }
}

extension DockSplitStore {
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId] else { return nil }
        return TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: transfer.agentRuntime?.agentPIDKeys ?? [],
            restoredAgentKind: transfer.restorableAgent?.kind.rawValue
        )
    }

    func terminalTabAgentIconAsset(for panel: any Panel, kind: DockSurfaceKind) -> String? {
        guard kind == .terminal else { return nil }
        return terminalTabAgentIconAsset(forPanelId: panel.id)
    }
}
