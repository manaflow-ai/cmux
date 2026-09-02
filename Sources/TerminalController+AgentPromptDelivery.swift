import CMUXAgentLaunch
import CmuxTerminal
import CmuxTerminalCore
import Foundation

extension TerminalController {
    /// Main-actor half of one serialized agent prompt request: resolve the
    /// workspace's agent terminal, reject any human composer state, then issue
    /// one compound paste-and-submit operation without suspension.
    func deliverAgentPromptSubmission(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        text: String,
        deliveryReceipt: PromptSubmissionDeliveryReceipt? = nil
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
            context: target.agentContext,
            agentInputScope: target.agentInputScope
        )
        let result = target.panel.sendPromptSubmissionResult(
            text,
            submitKey: submitKey,
            agentInputScope: target.agentInputScope,
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.agent_submit",
            deliveryReceipt: deliveryReceipt
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
            ),
                  let knownTarget = knownAgentPromptTarget(
                      surfaceID: surfaceID,
                      panel: target.panel,
                      workspace: workspace
                  ),
                  knownTarget.agentInputScope != nil,
                  agentPromptHookMatchesPanel(
                      in: workspace,
                      panelID: knownTarget.panel.id,
                      hookSource: event.source,
                      hookSessionID: event.sessionId,
                      hookPID: event.ppid
                  ) else {
                return nil
            }
            return knownTarget.panel
        }
        if let sessionPanel = agentPromptHookSessionPanel(
            in: workspace,
            hookSource: event.source,
            hookSessionID: event.sessionId,
            hookPID: event.ppid
        ) {
            return sessionPanel
        }
        // A surface-less hook without an exact source/session match is
        // intentionally unresolved; uniqueness is not proof of ownership.
        return nil
    }

    /// Resolves a hook target for legacy conversation side effects without
    /// requiring the narrower set of agents that support recoverable composer
    /// automation. Identity is still checked by surface/session and process
    /// metadata; this path never falls back to focus or uniqueness alone.
    func genericPromptEventPanel(
        in workspace: Workspace,
        event: WorkstreamEvent
    ) -> TerminalPanel? {
        if let rawSurfaceID = event.surfaceId {
            let normalizedSource = event.source.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let normalizedSessionID = normalizedHookSessionID(
                event.sessionId,
                source: normalizedSource
            ) else {
                return nil
            }
            guard let surfaceID = v2UUIDAny(rawSurfaceID),
                  let target = workspace.terminalInputTarget(
                      forPanelID: surfaceID
                  ),
                  genericPromptHookMatchesKeys(
                      workspace.agentPIDKeysByPanelId[surfaceID] ?? [],
                      hookSource: event.source,
                      hookSessionID: normalizedSessionID,
                      hookPID: event.ppid,
                      workspace: workspace,
                      allowSessionlessKey: true
                  ) else {
                return nil
            }
            return target.panel
        }

        let normalizedSource = event.source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalizedSessionID = normalizedHookSessionID(
            event.sessionId,
            source: normalizedSource
        ) else {
            return nil
        }
        var matchedPanels: [TerminalPanel] = []
        var seenPanelIDs: Set<UUID> = []
        for (key, panelID) in workspace.agentPIDPanelIdsByKey {
            guard genericPromptHookMatchesKeys(
                Set([key]),
                hookSource: normalizedSource,
                hookSessionID: normalizedSessionID,
                hookPID: event.ppid,
                workspace: workspace,
                allowSessionlessKey: false
            ),
                  seenPanelIDs.insert(panelID).inserted,
                  let panel = workspace.terminalInputTarget(
                      forPanelID: panelID
                  )?.panel else {
                continue
            }
            matchedPanels.append(panel)
        }
        return matchedPanels.count == 1 ? matchedPanels[0] : nil
    }

    private func genericPromptHookMatchesKeys(
        _ keys: Set<String>,
        hookSource: String,
        hookSessionID: String,
        hookPID: Int?,
        workspace: Workspace,
        allowSessionlessKey: Bool
    ) -> Bool {
        let source = hookSource.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !source.isEmpty,
              !hookSessionID.isEmpty,
              let hookPID else {
            return false
        }
        let expectedStatusKey = source == "claude"
            ? "claude_code"
            : source
        return keys.contains { key in
            guard workspace.agentStatusKey(forAgentPIDKey: key)
                    == expectedStatusKey else {
                return false
            }
            guard agentPromptHookProcessIdentityMatches(
                key: key,
                hookPID: hookPID,
                workspace: workspace
            ) else {
                return false
            }
            guard let separator = key.firstIndex(of: ".") else {
                return allowSessionlessKey && hookPID != nil
            }
            return key[key.index(after: separator)...] == hookSessionID
        }
    }

    /// Resolves a surface-less hook through the exact agent session token that
    /// cmux recorded with its process. Ambiguous or stale tokens fail closed.
    private func agentPromptHookSessionPanel(
        in workspace: Workspace,
        hookSource: String,
        hookSessionID: String,
        hookPID: Int?
    ) -> TerminalPanel? {
        let normalizedSource = hookSource.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalizedSessionID = normalizedHookSessionID(
            hookSessionID,
            source: normalizedSource
        ) else {
            return nil
        }
        let sourceContext = "agentPIDKey:\(normalizedSource)"
        var matchedPanels: [TerminalPanel] = []
        var seenPanelIDs: Set<UUID> = []

        // Start from the key→panel index so a surface-less hook does not
        // perform a process-identity lookup for every panel in a busy
        // workspace. Only exact source/session candidates reach the live
        // scope validation below.
        for (key, panelID) in workspace.agentPIDPanelIdsByKey {
            let matchesSession = agentPromptHookMatchesKeys(
                Set([key]),
                sourceContext: sourceContext,
                sessionID: normalizedSessionID,
                hookPID: hookPID,
                workspace: workspace,
                allowSessionlessKey: false
            )
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

    /// Matches a surface-scoped hook without scanning unrelated workspace panels.
    private func agentPromptHookMatchesPanel(
        in workspace: Workspace,
        panelID: UUID,
        hookSource: String,
        hookSessionID: String,
        hookPID: Int?
    ) -> Bool {
        let normalizedSource = hookSource.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalizedSessionID = normalizedHookSessionID(
            hookSessionID,
            source: normalizedSource
        ) else {
            return false
        }
        return agentPromptHookMatchesKeys(
            workspace.agentPIDKeysByPanelId[panelID] ?? [],
            sourceContext: "agentPIDKey:\(normalizedSource)",
            sessionID: normalizedSessionID,
            hookPID: hookPID,
            workspace: workspace,
            // The historical `claude_code` key carries no session token. An
            // explicit surface plus the current process identity is the
            // authoritative proof available for that legacy registration;
            // surface-less hooks remain session-qualified only.
            allowSessionlessKey: true
        )
    }

    private func agentPromptHookMatchesKeys(
        _ keys: Set<String>,
        sourceContext: String,
        sessionID: String,
        hookPID: Int?,
        workspace: Workspace,
        allowSessionlessKey: Bool
    ) -> Bool {
        keys.contains { key in
            guard TextBoxAgentDetection.representsSameAgentKind(
                "agentPIDKey:\(key)",
                sourceContext
            ) else {
                return false
            }
            guard agentPromptHookProcessIdentityMatches(
                key: key,
                hookPID: hookPID,
                workspace: workspace
            ) else {
                return false
            }
            guard let separator = key.firstIndex(of: ".") else {
                return allowSessionlessKey && key == "claude_code"
            }
            return key[key.index(after: separator)...] == sessionID
        }
    }

    /// Requires the hook's agent PID and birth timestamp to match the current
    /// registration, preventing a delayed event from a replaced process (or a
    /// reused PID) from clearing a newer composer boundary.
    private func agentPromptHookProcessIdentityMatches(
        key: String,
        hookPID: Int?,
        workspace: Workspace
    ) -> Bool {
        guard let rawPID = hookPID,
              rawPID > 0,
              let pid = pid_t(exactly: rawPID),
              workspace.agentPIDs[key] == pid,
              let recordedIdentity = workspace.agentPIDProcessIdentitiesByKey[key],
              Workspace.agentPIDProcessIdentity(pid: pid) == recordedIdentity else {
            return false
        }
        return true
    }

    private func normalizedHookSessionID(
        _ hookSessionID: String,
        source: String
    ) -> String? {
        let normalized = hookSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !source.isEmpty, !normalized.isEmpty else { return nil }
        let prefix = "\(source)-"
        if normalized.hasPrefix(prefix) {
            let rawSession = String(normalized.dropFirst(prefix.count))
            return rawSession.isEmpty ? nil : rawSession
        }
        return normalized
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
        guard workspace.agentPIDKeysByPanelId[panel.id]?.contains(where: {
            workspace.isPromptCapableAgentPIDKey($0)
        }) == true else {
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

    /// Clears a mobile chat prompt through the canonical socket-bound surface.
    func clearAgentPrompt(
        _ terminalTarget: ControlTerminalSocketTarget
    ) -> TerminalSurface.NamedKeySendResult {
        var latestAccepted: TerminalSurface.NamedKeySendResult = .sent
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalTarget.sendNamedKeyResult(keyName)
            guard result.accepted else { return result }
            latestAccepted = result
        }
        return latestAccepted
    }
}
