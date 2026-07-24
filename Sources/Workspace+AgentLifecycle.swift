import CmuxSidebar
import CmuxWorkspaces
import Foundation

extension Workspace {
    private static let agentRunningStatusReconciliationDelay: TimeInterval = 5

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

    func reconcileLiveIdleAgentStatus(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry
    ) {
        let statusKey = agentLifecycleStatusKey(for: observation.snapshot.kind)
        let lifecycleWatermark = statusKey.flatMap {
            agentLifecycleEventTimesByPanelId[panelId]?[$0]
        }
        let eventTime: TimeInterval
        if let runtimeStatusEventTime = observation.runtimeStatusEventTime {
            eventTime = runtimeStatusEventTime
        } else if lifecycleWatermark == nil {
            eventTime = observation.updatedAt
        } else {
            return
        }
        guard observation.lifecycle == .idle,
              Date().timeIntervalSince1970 - eventTime >= Self.agentRunningStatusReconciliationDelay,
              let statusKey,
              agentLifecycleStatesByPanelId[panelId]?[statusKey] == .running else {
            return
        }
        guard setAgentLifecycle(key: statusKey, panelId: panelId, lifecycle: .idle, agentEventTime: eventTime) else {
            return
        }
        guard let current = statusEntries[statusKey],
              current.agentOwnerPanelID == nil || current.agentOwnerPanelID == panelId else {
            return
        }
        _ = upsertSidebarStatusEntry(
            key: statusKey,
            value: String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle"),
            icon: "pause.circle.fill",
            color: "#8E8E93",
            url: current.url,
            priority: current.priority,
            format: current.format,
            panelId: panelId,
            pid: nil,
            agentEventTime: eventTime
        )
    }

    @discardableResult
    func upsertSidebarStatusEntry(
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat,
        panelId: UUID?,
        pid: pid_t?,
        agentEventTime: TimeInterval?
    ) -> SidebarStatusEntryReplacementDecision {
        let ownerPanelId = panelId
        let isStructuredAgentStatus = AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(key)
        let hasLifecycleWatermark = ownerPanelId.flatMap {
            agentLifecycleEventTimesByPanelId[$0]?[key]
        } != nil
        if let ownerPanelId,
           !acceptAgentRuntimeMutation(
               statusKey: key,
               panelId: ownerPanelId,
               agentEventTime: agentEventTime,
               enforceOrdering: agentEventTime != nil || hasLifecycleWatermark || isStructuredAgentStatus
           ) {
            return .stale
        }
        let replacementDecision = SidebarStatusEntry.replacementDecision(
            current: statusEntries[key],
            key: key,
            value: value,
            icon: icon,
            color: color,
            url: url,
            priority: priority,
            format: format,
            agentEventTime: agentEventTime,
            agentOwnerPanelID: ownerPanelId
        )
        switch replacementDecision {
        case .replace:
            statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: format,
                timestamp: Date(),
                agentEventTime: agentEventTime,
                agentOwnerPanelID: ownerPanelId
            )
            if let pid {
                recordAgentPID(
                    key: key,
                    pid: pid,
                    panelId: ownerPanelId,
                    agentEventTime: agentEventTime,
                    enforceAgentEventOrdering: true
                )
            }
        case .unchanged:
            if let pid {
                recordAgentPID(
                    key: key,
                    pid: pid,
                    panelId: ownerPanelId,
                    agentEventTime: agentEventTime,
                    enforceAgentEventOrdering: true
                )
            }
        case .stale:
            break
        }
        return replacementDecision
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
                _ = clearSurfaceResumeBinding(panelId: panelId)
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
        _ = clearSurfaceResumeBinding(panelId: panelId)
    }

    /// True when `binding` is a plain (non-tmux) agent-hook resume binding
    /// whose session no longer shows up as a live process. Generalizes the
    /// tmux-only `isProcessDetected` staleness signal in
    /// `reconcileSurfaceResumeBindings` so a normal exit of a resumed
    /// non-tmux agent doesn't leave a binding that gets replayed as a resume
    /// on the next relaunch (#8446).
    ///
    /// `restorableAgentIndex`, when supplied, is a freshly loaded index from
    /// the same scan generation as the caller's `SurfaceResumeBindingIndex`
    /// (see `ProcessDetectedResumeIndexes.load()`); prefer it over the
    /// separately TTL-cached `SharedLiveAgentIndex.shared.index` so pruning
    /// and the binding scan it is paired with always describe the same
    /// point-in-time snapshot instead of two independently stale ones.
    func isStaleAgentHookBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) -> Bool {
        // `RestorableAgentSessionIndex` / `SharedLiveAgentIndex` are built by
        // scanning LOCAL processes (pid/sysctl-based). A `.persistentSSH`
        // agent-hook binding's process runs on the remote host and can never
        // appear in that local scan, so treating it as this function's kind
        // of "stale" would prune every live remote agent-hook binding on the
        // very next reconciliation. Only judge local-launch bindings here;
        // remote bindings are left to whatever governs their own lifecycle.
        guard binding.isAgentHookBinding,
              binding.launchFlavor == .local,
              let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty,
              let kind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.isEmpty else {
            return false
        }
        let liveIndex = restorableAgentIndex ?? SharedLiveAgentIndex.shared.index
        return !AgentResumeLiveness.hasLiveProcess(
            for: liveIndex?.entry(workspaceId: id, panelId: panelId),
            kind: kind,
            sessionId: checkpointId
        )
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

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) -> Bool {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return false }
        guard acceptAgentRuntimeMutation(
            statusKey: key,
            panelId: targetPanelId,
            agentEventTime: agentEventTime,
            enforceOrdering: enforceAgentEventOrdering || agentEventTime != nil,
            isLifecycleMutation: true
        ) else { return false }
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
        if !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            recordAgentLifecycleChange(panelId: targetPanelId)
        }
        return true
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
        let removedEventTimes = agentLifecycleEventTimesByPanelId.removeValue(forKey: panelId) ?? [:]
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
                    if let eventTime = removedEventTimes[key] {
                        agentLifecycleEventTimesByPanelId[host, default: [:]][key] = eventTime
                    }
                }
            }
        }
        recordAgentLifecycleChange(panelId: panelId)
    }

    func clearAllAgentLifecycleStates() {
        let panelIds = Set(agentLifecycleStatesByPanelId.keys)
            .union(agentLifecycleEventTimesByPanelId.keys)
        guard !panelIds.isEmpty else { return }
        agentLifecycleStatesByPanelId.removeAll()
        agentLifecycleEventTimesByPanelId.removeAll()
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

    private func agentLifecycleStatusKey(for kind: RestorableAgentKind) -> String? {
        switch kind {
        case .claude:
            return "claude_code"
        case .hermesAgent:
            return "hermes-agent"
        case .custom(let id):
            return id
        default:
            return kind.rawValue
        }
    }

    private func recordAgentLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }
}
