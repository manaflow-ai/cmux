import Foundation

extension Workspace {
    func allowsAgentContinuation(forPanelId panelId: UUID) -> Bool {
        guard restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit else {
            return true
        }
        guard let indexedSnapshot = SharedLiveAgentIndex.shared.index?.snapshot(
            workspaceId: id,
            panelId: panelId
        ) else {
            return false
        }
        return !completedRestoredAgentMatches(panelId: panelId, candidate: indexedSnapshot)
    }

    func restoredAgentSnapshotForContinuation(
        panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        guard let snapshot = restoredAgentSnapshotsByPanelId[panelId],
              !completedRestoredAgentMatches(panelId: panelId, candidate: snapshot) else {
            return nil
        }
        return snapshot
    }

    func reconcileCompletedRestoredAgent(
        panelId: UUID,
        candidate: SessionRestorableAgentSnapshot
    ) {
        guard restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit,
              !completedRestoredAgentMatches(panelId: panelId, candidate: candidate) else {
            return
        }
        restoredAgentSnapshotsByPanelId[panelId] = candidate
        restoredAgentResumeStatesByPanelId[panelId] = restoredAgentResumeStateForAcceptedSnapshot(
            panelId: panelId
        )
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    private func completedRestoredAgentMatches(
        panelId: UUID,
        candidate: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit else {
            return false
        }
        guard let completed = restoredAgentSnapshotsByPanelId[panelId] else {
            return true
        }
        return completed.kind == candidate.kind && completed.sessionId == candidate.sessionId
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
        if let restorableAgent = detached.restorableAgent {
            restoredAgentSnapshotsByPanelId[detached.panelId] = restorableAgent
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: detached.panelId)
        } else {
            restoredAgentSnapshotsByPanelId.removeValue(forKey: detached.panelId)
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: detached.panelId)
        }
        if let resumeState = detached.restorableAgentResumeState {
            restoredAgentResumeStatesByPanelId[detached.panelId] = resumeState
        } else {
            restoredAgentResumeStatesByPanelId.removeValue(forKey: detached.panelId)
        }
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
