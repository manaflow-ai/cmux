import CmuxTerminal
import Foundation

extension TerminalController {
    /// Clears the agent TUI's current prompt through the same line-editor path
    /// used by mobile chat before a composed prompt is pasted.
    func clearAgentPrompt(_ terminalPanel: TerminalPanel) -> TerminalSurface.NamedKeySendResult {
        var latestAccepted: TerminalSurface.NamedKeySendResult = .sent
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalPanel.sendNamedKeyResult(keyName)
            guard result.accepted else { return result }
            latestAccepted = result
        }
        return latestAccepted
    }

    /// Main-actor half of one serialized agent prompt request: resolve the
    /// workspace's agent terminal, reject any human composer state, then issue
    /// one compound paste-and-submit operation without suspension.
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
        case .submissionUnavailable:
            return .submissionUnavailable(
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
        for panelID in workspace.panels.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
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
                surfaceIDs: candidates.map(\.surfaceID)
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
        guard TextBoxAgentDetection.supportsActiveAgentPrefixes(
            context: context
        ), let agentInputScope = workspace.agentPromptInputScope(
            forPanelId: panel.id
        ) else {
            return nil
        }
        return AgentPromptTerminalTarget(
            surfaceID: surfaceID,
            panel: panel,
            agentContext: context,
            agentInputScope: agentInputScope
        )
    }

}
