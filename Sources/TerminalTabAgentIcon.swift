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

    /// - Parameter registrationIconAssetName: In-memory lookup for registered
    ///   agent ids (callers back it with the panel's restorable-agent
    ///   registration; it must never do I/O — icon sync runs on the agent
    ///   PID/status mutation path). Consulted before the built-in switch so
    ///   config registrations can override built-in agents, matching
    ///   `CmuxVaultAgentRegistry` override semantics and the restored path.
    func assetName(
        liveAgents: [LiveAgent],
        restoredAgent: RestoredAgent?,
        registrationIconAssetName: (String) -> String? = { _ in nil }
    ) -> String? {
        let recognized = liveAgents.compactMap { agent -> (agent: LiveAgent, asset: String)? in
            let asset = registrationIconAssetName(agent.statusKey)
                ?? builtInAssetName(statusKey: agent.statusKey)
            return asset.map { (agent: agent, asset: $0) }
        }
        if let newest = recognized.min(by: { Self.isOrderedByRecency($0.agent, $1.agent) }) {
            return newest.asset
        }
        guard let restoredAgent else { return nil }
        return restoredAgent.registrationIconAssetName ?? builtInAssetName(statusKey: restoredAgent.kind)
    }

    /// - Parameter knownStatusKeys: Status keys known to be exact agent ids
    ///   (e.g. the keys of the runtime's status entries). Registered agent ids
    ///   may legally contain dots, so a raw PID key is only truncated at its
    ///   first dot when it is not itself a known status key — mirroring
    ///   `Workspace.agentStatusKey(forAgentPIDKey:)`, which exact-matches
    ///   against `statusEntries` before falling back to the prefix.
    func assetName(
        agentPIDKeys: Set<String>,
        processIdentities: [String: AgentPIDProcessIdentity] = [:],
        knownStatusKeys: Set<String> = [],
        restoredAgent: RestoredAgent?,
        registrationIconAssetName: (String) -> String? = { _ in nil }
    ) -> String? {
        assetName(
            liveAgents: agentPIDKeys.map { key in
                LiveAgent(
                    statusKey: knownStatusKeys.contains(key) ? key : statusKey(forAgentPIDKey: key),
                    processStart: processIdentities[key]
                )
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
        // Registered-agent icons resolve from the panel's restorable-agent
        // registration, which is already in memory. Icon sync runs on the
        // agent PID/status mutation path, so it must never load the Vault
        // registry (directory walk + config reads) itself. Known limit: a
        // custom registered agent running live before any restorable snapshot
        // is recorded shows the generic terminal icon; fixing that means
        // carrying the registration into live agent state at the lifecycle
        // recording boundary (TerminalController), not loading config here.
        let snapshot = restoredAgentSnapshotsByPanelId[panelId]
        let registration = snapshot?.registration
        return TerminalTabAgentIconResolver().assetName(
            liveAgents: liveAgents,
            restoredAgent: snapshot.map(TerminalTabAgentIconResolver.RestoredAgent.init(snapshot:)),
            registrationIconAssetName: { statusKey in
                registration?.id == statusKey ? registration?.iconAssetName : nil
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
        let registration = transfer.restorableAgent?.registration
        return TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: transfer.agentRuntime?.agentPIDKeys ?? [],
            processIdentities: transfer.agentRuntime?.agentPIDProcessIdentities ?? [:],
            knownStatusKeys: transfer.agentRuntime.map { Set($0.statusEntries.keys) } ?? [],
            restoredAgent: transfer.restorableAgent.map(
                TerminalTabAgentIconResolver.RestoredAgent.init(snapshot:)
            ),
            registrationIconAssetName: { statusKey in
                registration?.id == statusKey ? registration?.iconAssetName : nil
            }
        )
    }
}
