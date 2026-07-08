import Bonsplit
import Foundation

/// Resolves the asset-catalog brand mark shown in a terminal tab's fixed icon
/// slot from the panel's agent state: live agents win over a restored
/// (resumable) agent snapshot, and among several recognized live agents the
/// most recently started process wins, matching "the newest agent is the one
/// the user launched last".
struct TerminalTabAgentIconResolver {
    /// One live agent candidate: its normalized status key plus the recorded
    /// process start identity used to order concurrent agents by recency.
    struct LiveAgent {
        let statusKey: String
        let processStart: AgentPIDProcessIdentity?
    }

    func assetName(liveAgents: [LiveAgent], restoredAgentKind: String?) -> String? {
        let recognized = liveAgents.compactMap { agent in
            assetName(statusKey: agent.statusKey).map { (agent: agent, asset: $0) }
        }
        if let newest = recognized.min(by: { Self.isOrderedByRecency($0.agent, $1.agent) }) {
            return newest.asset
        }
        guard let restoredAgentKind else { return nil }
        return assetName(statusKey: restoredAgentKind)
    }

    func assetName(
        agentPIDKeys: Set<String>,
        processIdentities: [String: AgentPIDProcessIdentity] = [:],
        restoredAgentKind: String?
    ) -> String? {
        assetName(
            liveAgents: agentPIDKeys.map { key in
                LiveAgent(statusKey: statusKey(forAgentPIDKey: key), processStart: processIdentities[key])
            },
            restoredAgentKind: restoredAgentKind
        )
    }

    /// Newest process start first; agents with a recorded start identity rank
    /// ahead of agents without one; equal recency falls back to ascending
    /// status key so the choice stays deterministic.
    private static func isOrderedByRecency(_ lhs: LiveAgent, _ rhs: LiveAgent) -> Bool {
        switch (lhs.processStart, rhs.processStart) {
        case let (lhsStart?, rhsStart?):
            if lhsStart.startSeconds != rhsStart.startSeconds {
                return lhsStart.startSeconds > rhsStart.startSeconds
            }
            if lhsStart.startMicroseconds != rhsStart.startMicroseconds {
                return lhsStart.startMicroseconds > rhsStart.startMicroseconds
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return lhs.statusKey < rhs.statusKey
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
        let liveAgents = (agentPIDKeysByPanelId[panelId] ?? []).map { key in
            TerminalTabAgentIconResolver.LiveAgent(
                statusKey: agentStatusKey(forAgentPIDKey: key),
                processStart: agentPIDProcessIdentitiesByKey[key]
            )
        }
        return TerminalTabAgentIconResolver().assetName(
            liveAgents: liveAgents,
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

    /// Convenience for agent-lifecycle call sites that may touch several
    /// panels at once (e.g. an agent PID moving between panels).
    func syncTerminalTabAgentIconAssets(forPanelIds panelIds: UUID?...) {
        for case let panelId? in panelIds {
            syncTerminalTabAgentIconAsset(forPanelId: panelId)
        }
    }

    func syncTerminalTabAgentIconAssetsForAllTerminalPanels() {
        for (panelId, panel) in panels where panel is TerminalPanel {
            syncTerminalTabAgentIconAsset(forPanelId: panelId)
        }
    }
}

extension DockSplitStore {
    /// Dock tabs resolve from the detached transfer snapshot: the Dock
    /// receives no agent lifecycle updates by design (same contract as the
    /// transfer's resume metadata), and `detachSurface` re-reconciles agent
    /// state, dropping proven-exited agents, when the surface leaves the Dock.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId] else { return nil }
        return TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: transfer.agentRuntime?.agentPIDKeys ?? [],
            processIdentities: transfer.agentRuntime?.agentPIDProcessIdentities ?? [:],
            restoredAgentKind: transfer.restorableAgent?.kind.rawValue
        )
    }
}
