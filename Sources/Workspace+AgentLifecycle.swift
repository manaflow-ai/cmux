import CmuxWorkspaces
import Foundation

extension Workspace {
    func allowsAgentContinuation(forPanelId panelId: UUID) -> Bool {
        restoredAgentResumeStatesByPanelId[panelId] != .completedAgentExit ||
            restoredAgentSnapshotForContinuation(panelId: panelId) != nil
    }

    func restoredAgentSnapshotForContinuation(
        panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        restoredAgentLifecycle.continuationSnapshot(
            panelId: panelId,
            observation: SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: id,
                panelId: panelId
            ),
            currentProcessIdentity: Self.agentPIDProcessIdentity(pid:)
        )
    }

    func reconcileCompletedRestoredAgent(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry
    ) {
        restoredAgentLifecycle.reconcileCompletedAgent(
            panelId: panelId,
            observation: observation,
            currentProcessIdentity: Self.agentPIDProcessIdentity(pid:)
        )
    }

    func markRestoredAgentCompleted(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) {
        let runtimeProcessIdentities = Set((agentPIDKeysByPanelId[panelId] ?? []).compactMap {
            agentPIDProcessIdentitiesByKey[$0]
        })
        restoredAgentLifecycle.markCompleted(
            panelId: panelId,
            observation: SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: id,
                panelId: panelId
            ),
            runtimeProcessIdentities: runtimeProcessIdentities
        )
    }

    func restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID) -> RestoredAgentResumeState {
        panelShellActivityStates[panelId] == .commandRunning
            ? .observedAgentCommandRunning
            : .manualResumeAvailable
    }

    func updateRestoredAgentResumeState(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot,
        shellState: PanelShellActivityState
    ) {
        switch shellState {
        case .commandRunning:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.awaitingAutoResumeCommand):
                restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning),
                 .some(.completedAgentExit):
                break
            case .some(.manualResumeAvailable), nil:
                invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
            }
        case .promptIdle:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                markRestoredAgentCompleted(panelId: panelId, snapshot: restoredAgent)
                restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
                clearRestoredAgentResumeBinding(panelId: panelId, restoredAgent: restoredAgent)
            case .some(.awaitingAutoResumeCommand), .some(.manualResumeAvailable), .some(.completedAgentExit), nil:
                break
            }
        case .unknown:
            break
        }
    }

    func updateBindingOnlyRestoredAgentResumeState(
        panelId: UUID,
        shellState: PanelShellActivityState
    ) {
        switch (shellState, restoredAgentResumeStatesByPanelId[panelId]) {
        case (.commandRunning, .some(.awaitingAutoResumeCommand)):
            restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            if surfaceResumeBindingsByPanelId[panelId]?.isAgentHookBinding == true {
                surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
            }
        default:
            break
        }
    }

    private func invalidateRestoredAgentSnapshot(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(restoredAgent)
        invalidatedRestoredAgentFingerprintsByPanelId[panelId] = fingerprint
        clearRestoredAgentResumeBinding(panelId: panelId, restoredAgent: restoredAgent)
        clearRestoredAgentSnapshot(panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "session.restore.agent.invalidate panel=\(panelId.uuidString.prefix(5)) " +
            "kind=\(restoredAgent.kind.rawValue) session=\(restoredAgent.sessionId.prefix(8))"
        )
#endif
    }

    private func clearRestoredAgentResumeBinding(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        guard let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.source == "agent-hook" else {
            return
        }
        let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checkpointId == nil || checkpointId == restoredAgent.sessionId else {
            return
        }
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
    }

    func seedSessionRestoredAgentState(
        panelId: UUID,
        restorableAgent: SessionRestorableAgentSnapshot?,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool
    ) {
        if let restorableAgent {
            restoredAgentSnapshotsByPanelId[panelId] = restorableAgent
        } else {
            restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        }
        if willRunStartupCommand {
            restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
        } else if willRunStartupInput {
            restoredAgentResumeStatesByPanelId[panelId] = .awaitingAutoResumeCommand
        } else if restorableAgent != nil {
            restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable
        } else {
            restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        }
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    func seedDetachedRestoredAgentState(from detached: DetachedSurfaceTransfer) {
        if let shellActivityState = detached.shellActivityState {
            panelShellActivityStates[detached.panelId] = shellActivityState
            (detached.panel as? TerminalPanel)?.updateShellActivityState(shellActivityState)
        } else {
            panelShellActivityStates.removeValue(forKey: detached.panelId)
        }
        restoredAgentLifecycle.seedTransferredState(
            panelId: detached.panelId,
            snapshot: detached.restorableAgent,
            resumeState: detached.restorableAgentResumeState,
            completedGeneration: detached.restoredAgentCompletedGeneration
        )
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: detached.panelId)
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState
    ) {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return }
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
        if !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            recordAgentLifecycleChange(panelId: targetPanelId)
        }
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        var didClear = false
        let recordsHibernationActivity = !AgentHibernationLifecycleStatusKeys.isManualKey(key)
        let panelIds = panelId.map { [$0] } ?? Array(agentLifecycleStatesByPanelId.keys)
        for panelId in panelIds {
            guard agentLifecycleStatesByPanelId[panelId]?[key] != nil else { continue }
            agentLifecycleStatesByPanelId[panelId]?.removeValue(forKey: key)
            if agentLifecycleStatesByPanelId[panelId]?.isEmpty == true {
                agentLifecycleStatesByPanelId.removeValue(forKey: panelId)
            }
            didClear = true
            if recordsHibernationActivity {
                recordAgentLifecycleChange(panelId: panelId)
            }
        }
        return didClear
    }

    func hasRunningAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        if let panelId {
            return agentLifecycleStatesByPanelId[panelId]?[key] == .running
        }
        return agentLifecycleStatesByPanelId.values.contains { $0[key] == .running }
    }

    func clearAgentLifecycleStates(panelId: UUID) {
        guard let removed = agentLifecycleStatesByPanelId.removeValue(forKey: panelId) else { return }
        let manualStates = removed.filter { AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
        if !manualStates.isEmpty {
            let host: UUID? = if panels[panelId] != nil {
                panelId
            } else if let focused = focusedPanelId, focused != panelId, panels[focused] != nil {
                focused
            } else {
                panels.keys.first(where: { $0 != panelId })
            }
            if let host {
                for (key, lifecycle) in manualStates {
                    agentLifecycleStatesByPanelId[host, default: [:]][key] = lifecycle
                }
            }
        }
        recordAgentLifecycleChange(panelId: panelId)
    }

    func clearAllAgentLifecycleStates() {
        let panelIds = Array(agentLifecycleStatesByPanelId.keys)
        guard !panelIds.isEmpty else { return }
        agentLifecycleStatesByPanelId.removeAll()
        for panelId in panelIds {
            recordAgentLifecycleChange(panelId: panelId)
        }
    }

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        let states = (agentLifecycleStatesByPanelId[panelId] ?? [:])
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value)
        guard !states.isEmpty else {
            return fallback ?? .unknown
        }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    private func recordAgentLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }
}
