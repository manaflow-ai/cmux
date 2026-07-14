import AppKit
import Foundation

/// A built-in coding agent (codex, claude, cursor, gemini, …) detected running as a CLI
/// in a terminal pane by pure process inspection. Display-only: it drives the surface
/// tab and sidebar workspace-row brand icon and carries NO session identity, so it never
/// participates in agent session restore/resume.
struct DetectedBuiltInAgent: Sendable, Equatable {
    /// The matched built-in definition's `id` (e.g. `"codex"`, `"cursor"`). Rendering
    /// resolves this to a brand asset via `RestorableAgentKind(rawValue:)?.agentIconAssetName`
    /// (the authoritative kind→asset mapping), falling back to the sparkles symbol when the
    /// kind has no bundled asset.
    let agentId: String

    /// The restorable kind this built-in id resolves to, or `nil` when the id is not a
    /// known kind. Used to reach the authoritative `agentIconAssetName` mapping.
    var restorableAgentKind: RestorableAgentKind? {
        RestorableAgentKind(rawValue: agentId)
    }

    /// Authoritative asset-catalog name for this detected agent's brand mark, or `nil`
    /// when the kind has no bundled asset (render the `sparkles.rectangle.stack`
    /// fallback). Routes through `RestorableAgentKind.agentIconAssetName` — the single
    /// source of truth — rather than the definition's own `assetName`.
    var agentIconAssetName: String? {
        restorableAgentKind?.agentIconAssetName
    }

    /// PNG `Data` for this detected agent's brand mark suitable for a tab's
    /// `iconImageData:` channel, or `nil` when no bundled asset applies.
    @MainActor
    func agentIconPNGData(appearance: NSAppearance? = nil) -> Data? {
        agentBrandIconPNGData(assetName: agentIconAssetName, appearance: appearance)
    }
}

extension RestorableAgentSessionIndex {
    /// Detects BUILT-IN coding agents running directly as terminal CLIs and maps each to its
    /// workspace/panel. Built-in agents are defined by `CmuxTaskManagerCodingAgentDefinition.builtIns`
    /// and matched by `matchingDefinition(...)`. Unlike `processDetectedSnapshots` (which only
    /// covers opencode + Vault-registry agents and requires a resolvable session id), this is a
    /// display-only signal: a bare `codex` CLI that fires no cmux hook and exposes no session id
    /// still surfaces its brand icon.
    ///
    /// Runs off-main (caller drives cadence). Reuses the same `CmuxTopProcessSnapshot` scope
    /// attribution (`cmuxWorkspaceID` / `cmuxSurfaceID`) as the vault scanner.
    static func detectedBuiltInAgentIconsByPanel(
        processSnapshot: CmuxTopProcessSnapshot,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> [PanelKey: DetectedBuiltInAgent] {
        var resolved: [PanelKey: DetectedBuiltInAgent] = [:]
        let scoped = processSnapshot.cmuxScopedProcesses()

        func matchedAgent(for process: CmuxTopProcessInfo) -> DetectedBuiltInAgent? {
            let processArguments = processArgumentsProvider(process.pid)
            guard let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments?.arguments ?? [],
                environment: processArguments?.environment ?? [:]
            ) else { return nil }
            return DetectedBuiltInAgent(agentId: definition.id)
        }

        func assign(preferringForeground foregroundOnly: Bool) {
            for process in scoped {
                if foregroundOnly, !process.isTerminalForegroundProcessGroup { continue }
                guard let workspaceId = process.cmuxWorkspaceID,
                      let panelId = process.cmuxSurfaceID else { continue }
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                guard resolved[key] == nil, let agent = matchedAgent(for: process) else { continue }
                resolved[key] = agent
            }
        }

        // A pane hosts several scoped processes (shell + agent + MCP/helper children), and a
        // background child can carry a DIFFERENT agent's signal (e.g. an opencode pane whose
        // env inherits claude-wrapper vars). Prefer the terminal FOREGROUND process — the agent
        // the user is actually interacting with — and only fall back to a background match when
        // no foreground process in the pane matches a known agent.
        assign(preferringForeground: true)
        assign(preferringForeground: false)
        return resolved
    }
}
