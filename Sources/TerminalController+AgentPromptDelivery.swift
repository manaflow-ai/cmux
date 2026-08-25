import CMUXAgentLaunch
import CmuxTerminalCore
import CmuxTerminal
import Foundation

extension TerminalController {
    /// Main-actor half of one serialized agent prompt request: resolve the
    /// workspace's agent terminal, admit one compound transaction, and queue it
    /// untouched when a human draft or active turn owns the composer.
    func deliverAgentPromptSubmission(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        text: String
    ) -> AgentPromptSubmissionResult {
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID)
                ?? (self.tabManager?.tabs.contains(where: { $0.id == workspaceID }) == true
                    ? self.tabManager
                    : nil),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .workspaceNotFound(workspaceID: workspaceID)
        }

        let target: AgentPromptTerminalTarget
        switch agentPromptTerminalTarget(
            in: workspace,
            requestedSurfaceID: requestedSurfaceID
        ) {
        case .success(let resolved):
            target = resolved
        case .failure(let failure):
            return failure
        }

        // A hook-observed agent turn owns the composer. Shell activity cannot
        // gate this: a TUI agent keeps the shell in `commandRunning` even
        // while its composer sits idle, so the hook-derived turn state is the
        // busy signal. The stop hook (and the confirmation-timeout fallback)
        // drains the queue afterwards.
        if !target.panel.isAgentHibernated,
           workspace.hasActiveAgentTurn(panelId: target.surfaceID) {
            return .agentBusy(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        }
        if target.panel.isAgentHibernated {
            // Wake without focus and keep the message in the app FIFO until
            // the resumed agent process identity is rebound.
            _ = target.panel.prepareAgentHibernationResume()
            return .agentScopeUnavailable(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        }
        guard target.panel.surface.surface != nil else {
            // A cold surface means the agent runtime is not up yet; the
            // request stays in the app FIFO instead of the terminal input
            // queue so it cannot flush into a starting shell.
            return .agentScopeUnavailable(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        }

        let submitKey = TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: text.contains("\n") || text.contains("\r"),
            context: target.agentContext
        )
        let result = target.panel.sendPromptSubmissionResult(
            text,
            submitKey: submitKey,
            agentInputScope: target.agentInputScope,
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.agent_submit",
            deferDuringRuntimeClipboardRead: false
        )
        switch result {
        case .sent, .queued:
            if result == .sent {
                target.panel.surface.forceRefresh(
                    reason: "terminalController.agentPromptSubmission"
                )
            }
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID,
                queued: result == .queued
            )
        case .composerBusy:
            return .rejectedComposerBusy(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        case .agentScopeUnavailable:
            return .agentScopeUnavailable(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        case .unknownKey:
            return .invalidSubmitKey(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        case .inputQueueFull:
            return .inputQueueFull(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        case .surfaceUnavailable:
            return .surfaceUnavailable(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        case .processExited:
            return .processExited(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        }
    }

    /// Resolves the surface that owns a prompt-submission hook. Hooks that omit
    /// surface identity may fall back only to one authoritative agent terminal;
    /// an explicit invalid or stale identity remains unresolved.
    func agentPromptConfirmationPanel(
        in workspace: Workspace,
        event: WorkstreamEvent
    ) -> TerminalPanel? {
        if let rawSurfaceID = event.surfaceId {
            guard let surfaceID = v2UUIDAny(rawSurfaceID) else {
                return nil
            }
            guard let target = workspace.terminalInputTarget(
                forPanelID: surfaceID
            ), knownAgentPromptTarget(
                surfaceID: target.surfaceID,
                panel: target.panel,
                workspace: workspace
            )?.agentInputScope != nil else {
                return nil
            }
            return target.panel
        }
        if let sessionPanel = agentPromptHookSessionPanel(
            in: workspace,
            hookSource: event.source,
            hookSessionID: event.sessionId
        ) {
            return sessionPanel
        }
        // A hook that names a session unknown to every recorded same-kind
        // agent session in this workspace belongs to another process — e.g.
        // a cmux-spawned headless utility run that inherited the workspace
        // environment. Attributing it to the interactive terminal would
        // consume a human draft boundary and flap the turn state.
        if agentPromptHookNamesForeignSession(
            in: workspace,
            hookSource: event.source,
            hookSessionID: event.sessionId
        ) {
            return nil
        }
        guard case .success(let target) = agentPromptTerminalTarget(
            in: workspace,
            requestedSurfaceID: nil
        ), target.agentInputScope != nil else {
            return nil
        }
        return target.panel
    }

    /// Whether a surface-less hook names a session that no recorded
    /// same-kind agent session in the workspace matches. Returns false when
    /// the workspace has no recorded same-kind session to compare against,
    /// so early-startup hooks keep the single-agent fallback.
    private func agentPromptHookNamesForeignSession(
        in workspace: Workspace,
        hookSource: String,
        hookSessionID: String
    ) -> Bool {
        let normalizedSource = hookSource.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedSessionID = hookSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedSource.isEmpty, !normalizedSessionID.isEmpty else {
            return false
        }
        let sourceContext = "agentPIDKey:\(normalizedSource)"
        var sawSameKindSessionKey = false
        for keys in workspace.agentPIDKeysByPanelId.values {
            for key in keys {
                guard let separator = key.firstIndex(of: "."),
                      TextBoxAgentDetection.representsSameAgentKind(
                          "agentPIDKey:\(key)",
                          sourceContext
                      ) else { continue }
                sawSameKindSessionKey = true
                if key[key.index(after: separator)...] == normalizedSessionID {
                    return false
                }
            }
        }
        return sawSameKindSessionKey
    }

    /// Resolves a surface-less hook through the exact agent session token that
    /// cmux recorded with its process. Ambiguous or stale tokens fail closed.
    private func agentPromptHookSessionPanel(
        in workspace: Workspace,
        hookSource: String,
        hookSessionID: String
    ) -> TerminalPanel? {
        let normalizedSource = hookSource.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedSessionID = hookSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedSource.isEmpty,
              !normalizedSessionID.isEmpty else {
            return nil
        }
        let sourceContext = "agentPIDKey:\(normalizedSource)"
        var matchedPanels: [TerminalPanel] = []
        var seenPanelIDs: Set<UUID> = []

        for (panelID, keys) in workspace.agentPIDKeysByPanelId {
            let matchesSession = keys.contains { key in
                guard let separator = key.firstIndex(of: ".") else {
                    return false
                }
                let sessionID = key[key.index(after: separator)...]
                guard sessionID == normalizedSessionID else {
                    return false
                }
                return TextBoxAgentDetection.representsSameAgentKind(
                    "agentPIDKey:\(key)",
                    sourceContext
                )
            }
            guard matchesSession,
                  seenPanelIDs.insert(panelID).inserted,
                  workspace.agentPromptInputScope(
                      forPanelId: panelID
                  ) != nil,
                  let panel = workspace.terminalInputTarget(
                      forPanelID: panelID
                  )?.panel else {
                continue
            }
            matchedPanels.append(panel)
        }
        return matchedPanels.count == 1 ? matchedPanels[0] : nil
    }

    private func agentPromptTerminalTarget(
        in workspace: Workspace,
        requestedSurfaceID: UUID?
    ) -> AgentPromptTerminalTargetResolution {
        if let requestedSurfaceID {
            guard let target = workspace.terminalInputTarget(
                forPanelID: requestedSurfaceID
            ) else {
                return .failure(.surfaceNotFound(
                    workspaceID: workspace.id,
                    surfaceID: requestedSurfaceID
                ))
            }
            guard let resolved = knownAgentPromptTarget(
                surfaceID: target.surfaceID,
                panel: target.panel,
                workspace: workspace
            ) else {
                return .failure(.agentNotFound(
                    workspaceID: workspace.id,
                    requestedSurfaceID: requestedSurfaceID
                ))
            }
            return .success(resolved)
        }

        var candidates: [AgentPromptTerminalTarget] = []
        var seenSurfaceIDs: Set<UUID> = []
        for panelID in workspace.panels.keys {
            for panel in workspace.terminalPanels(projectedFromPanelID: panelID)
                where seenSurfaceIDs.insert(panel.id).inserted {
                if let resolved = knownAgentPromptTarget(
                    surfaceID: panel.id,
                    panel: panel,
                    workspace: workspace
                ) {
                    candidates.append(resolved)
                }
            }
        }
        switch candidates.count {
        case 1:
            return .success(candidates[0])
        case 2...:
            return .failure(.ambiguousAgent(
                workspaceID: workspace.id,
                surfaceIDs: candidates.map(\.surfaceID).sorted {
                    $0.uuidString < $1.uuidString
                }
            ))
        default:
            return .failure(.agentNotFound(
                workspaceID: workspace.id,
                requestedSurfaceID: nil
            ))
        }
    }

    private func knownAgentPromptTarget(
        surfaceID: UUID,
        panel: TerminalPanel,
        workspace: Workspace
    ) -> AgentPromptTerminalTarget? {
        let context = WorkspaceContentView.terminalAgentContext(
            panel: panel,
            workspace: workspace
        )
        let liveAgent = workspace.agentPIDKeysByPanelId[panel.id]?.contains(where: {
            workspace.isPromptCapableAgentPIDKey($0)
        }) == true
        let hibernatedAgentKind: String? =
            panel.agentHibernationState?.agent.kind.rawValue
        let hibernatedAgent = panel.isAgentHibernated
            && hibernatedAgentKind.map { kind in
                TextBoxAgentDetection.supportsActiveAgentPrefixes(
                    context: "agentPIDKey:\(kind)"
                )
            } == true
        guard liveAgent || hibernatedAgent else {
            return nil
        }
        return AgentPromptTerminalTarget(
            surfaceID: surfaceID,
            panel: panel,
            agentContext: context,
            agentInputScope: workspace.agentPromptInputScope(
                forPanelId: panel.id
            )
        )
    }

}
