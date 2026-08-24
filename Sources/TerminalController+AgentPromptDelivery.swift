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

        // A running agent owns the foreground turn. Holding the request in the
        // app FIFO avoids writing into a composer that the agent may redraw or
        // consume mid-turn; the idle hook/shell-state transition drains it.
        let shellState = workspace.panelShellActivityStates[target.surfaceID]
        if !target.panel.isAgentHibernated,
           shellState != .some(.promptIdle) {
            return .agentBusy(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        }
        if target.panel.isAgentHibernated {
            // Wake without focus and keep the message in the app FIFO until
            // the resumed runtime reports an authoritative idle prompt.
            _ = target.panel.prepareAgentHibernationResume()
            return .agentBusy(
                workspaceID: workspaceID,
                surfaceID: target.surfaceID
            )
        }
        guard target.panel.surface.surface != nil else {
            return .agentBusy(
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
            hookRecordingSource: "workspace.agent_submit"
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
            ) != nil else {
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
        guard case .success(let target) = agentPromptTerminalTarget(
            in: workspace,
            requestedSurfaceID: nil
        ), target.agentInputScope != nil else {
            return nil
        }
        return target.panel
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
        let hibernatedAgent = panel.isAgentHibernated
            && panel.agentHibernationState?.agent.kind.rawValue
                .map { TextBoxAgentDetection.supportsActiveAgentPrefixes(
                    context: "agentPIDKey:\($0)"
                ) } == true
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
