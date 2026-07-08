import Bonsplit
import Foundation

/// Resolves the asset-catalog brand mark shown in a terminal tab's fixed icon
/// slot from the panel's agent state: live agents win over a restored
/// (resumable) agent snapshot, and among several recognized live agents the
/// most recently started process wins, matching "the newest agent is the one
/// the user launched last". Registry-owned agents (Vault registrations,
/// including project-config overrides) resolve through their registration's
/// `iconAssetName` so this file never becomes a second source of truth for
/// registered-agent branding.
nonisolated struct TerminalTabAgentIconResolver {
    /// One live agent candidate: its normalized status key plus the recorded
    /// process start identity used to order concurrent agents by recency.
    struct LiveAgent {
        let statusKey: String
        let processStart: AgentPIDProcessIdentity?
    }

    /// A restored (resumable) agent snapshot's icon inputs. The registration
    /// icon, when present, is authoritative: registrations can override
    /// built-in agents (e.g. project-config pi/grok) and carry custom agents
    /// the built-in switch cannot know about.
    struct RestoredAgent {
        let kind: String
        let registrationIconAssetName: String?
    }

    /// - Parameter registrationIconAssetName: Lazy lookup for live status keys
    ///   that are not built-in agents (registered/vault agents). Only consulted
    ///   for keys the built-in switch does not recognize, so callers can back
    ///   it with a registry load without paying that cost on common paths.
    func assetName(
        liveAgents: [LiveAgent],
        restoredAgent: RestoredAgent?,
        registrationIconAssetName: (String) -> String? = { _ in nil }
    ) -> String? {
        let recognized = liveAgents.compactMap { agent -> (agent: LiveAgent, asset: String)? in
            let asset = builtInAssetName(statusKey: agent.statusKey)
                ?? registrationIconAssetName(agent.statusKey)
            return asset.map { (agent: agent, asset: $0) }
        }
        if let newest = recognized.min(by: { Self.isOrderedByRecency($0.agent, $1.agent) }) {
            return newest.asset
        }
        guard let restoredAgent else { return nil }
        return restoredAgent.registrationIconAssetName ?? builtInAssetName(statusKey: restoredAgent.kind)
    }

    func assetName(
        agentPIDKeys: Set<String>,
        processIdentities: [String: AgentPIDProcessIdentity] = [:],
        restoredAgent: RestoredAgent?,
        registrationIconAssetName: (String) -> String? = { _ in nil }
    ) -> String? {
        assetName(
            liveAgents: agentPIDKeys.map { key in
                LiveAgent(statusKey: statusKey(forAgentPIDKey: key), processStart: processIdentities[key])
            },
            restoredAgent: restoredAgent,
            registrationIconAssetName: registrationIconAssetName
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

    private func builtInAssetName(statusKey: String) -> String? {
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

extension TerminalTabAgentIconResolver.RestoredAgent {
    init(snapshot: SessionRestorableAgentSnapshot) {
        self.init(
            kind: snapshot.kind.rawValue,
            registrationIconAssetName: snapshot.registration?.iconAssetName
        )
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
        // Loaded at most once per resolution, and only when a live key is not
        // a built-in agent (mirrors the lifecycle-key validation path, which
        // already loads the registry per accepted registered-agent event).
        var loadedRegistry: CmuxVaultAgentRegistry?
        return TerminalTabAgentIconResolver().assetName(
            liveAgents: liveAgents,
            restoredAgent: restoredAgentSnapshotsByPanelId[panelId].map(
                TerminalTabAgentIconResolver.RestoredAgent.init(snapshot:)
            ),
            registrationIconAssetName: { statusKey in
                guard CmuxVaultAgentRegistration.isValidID(statusKey) else { return nil }
                if loadedRegistry == nil {
                    loadedRegistry = CmuxVaultAgentRegistry.load(
                        workingDirectory: effectivePanelDirectory(panelId: panelId)
                    )
                }
                return loadedRegistry?.registration(id: statusKey)?.iconAssetName
            }
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
            restoredAgent: transfer.restorableAgent.map(
                TerminalTabAgentIconResolver.RestoredAgent.init(snapshot:)
            )
        )
    }
}
