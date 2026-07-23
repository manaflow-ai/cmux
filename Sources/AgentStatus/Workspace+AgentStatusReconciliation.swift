import CMUXAgentLaunch
import CmuxSidebar
import CmuxWorkspaces
import Darwin
import Foundation

extension Workspace {
    private var agentStatusLedger: AgentStatusRuntimeLedger {
        sidebarAgentRuntimeObservation.agentStatusLedger
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        runtimePIDKey: String? = nil,
        runtimePID: Int? = nil,
        runtimeProcessIdentity: AgentPIDProcessIdentity? = nil,
        revision: UInt64? = nil
    ) -> Bool {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return false }
        guard AgentHibernationLifecycleStatusKeys.isAllowed(key) else {
            agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
            if !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
                recordAgentLifecycleChange(panelId: targetPanelId)
            }
            return true
        }
        if let runtimePIDKey, let runtimePID,
           !agentStatusRuntimeIsCurrent(
               pidKey: runtimePIDKey,
               pid: runtimePID,
               runtimeProcessIdentity: runtimeProcessIdentity,
               panelId: targetPanelId
           ) {
            return false
        }
        let observedAt = Date.now
        guard agentStatusLedger.recordLifecycle(
            lifecycle,
            panelId: targetPanelId,
            statusKey: key,
            observedAt: observedAt,
            runtimePIDKey: runtimePIDKey,
            runtimeProcessIdentity: runtimeProcessIdentity,
            revision: revision
        ) else { return false }
        resetAgentStatusShellReportDedupe(panelId: targetPanelId)
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
        recordAgentLifecycleChange(panelId: targetPanelId)
        reconcileAgentStatuses(panelId: targetPanelId, now: observedAt)
        return true
    }

    @discardableResult
    func noteAgentStatusHookSignal(
        _ signal: AgentStatusHookEventSignal,
        panelId: UUID?
    ) -> Bool {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId,
              agentStatusRuntimeIsCurrent(
                  pidKey: signal.runtimePIDKey,
                  pid: signal.runtimePID,
                  pidNamespace: signal.runtimePIDNamespace,
                  runtimeProcessIdentity: signal.runtimeProcessIdentity,
                  panelId: targetPanelId
              ) else {
            return false
        }
        guard agentStatusLedger.recordLifecycle(
            signal.lifecycle,
            panelId: targetPanelId,
            statusKey: signal.statusKey,
            observedAt: signal.observedAt,
            runtimePIDKey: signal.runtimePIDKey,
            runtimeProcessIdentity: signal.runtimeProcessIdentity,
            revision: signal.revision
        ) else { return false }
        resetAgentStatusShellReportDedupe(panelId: targetPanelId)
        reconcileAgentStatuses(panelId: targetPanelId, now: signal.observedAt)
        return true
    }

    func agentStatusRuntimeIsCurrent(event: WorkstreamEvent, panelId: UUID) -> Bool {
        guard let runtime = AgentStatusHookEventSignal.runtimeBinding(event: event) else {
            return false
        }
        return agentStatusRuntimeIsCurrent(
            pidKey: runtime.pidKey,
            pid: runtime.pid,
            pidNamespace: runtime.pidNamespace,
            panelId: panelId
        )
    }

    func applyAgentStatusBlockingDecisionHookSignal(
        event: WorkstreamEvent,
        panelId: UUID
    ) -> Bool {
        guard FeedCoordinator.isBlockingDecisionEvent(event.hookEventName),
              event.ppid != nil,
              let signal = AgentStatusHookEventSignal(event: event),
              signal.lifecycle == .needsInput else { return false }
        return noteAgentStatusHookSignal(signal, panelId: panelId)
    }

    @discardableResult
    func resumeAgentLifecycleIfNeedsInput(
        key: String,
        panelId: UUID?,
        runtimePIDKey: String? = nil,
        runtimePID: Int? = nil,
        runtimeProcessIdentity: AgentPIDProcessIdentity? = nil,
        revision: UInt64? = nil
    ) -> Bool {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return false }
        if let runtimePIDKey, let runtimePID,
           !agentStatusRuntimeIsCurrent(
               pidKey: runtimePIDKey,
               pid: runtimePID,
               runtimeProcessIdentity: runtimeProcessIdentity,
               panelId: targetPanelId
           ) {
            return false
        }
        let observedAt = Date.now
        guard agentStatusLedger.recordLifecycle(
            .running,
            panelId: targetPanelId,
            statusKey: key,
            observedAt: observedAt,
            runtimePIDKey: runtimePIDKey,
            runtimeProcessIdentity: runtimeProcessIdentity,
            revision: revision
        ) else { return false }
        resetAgentStatusShellReportDedupe(panelId: targetPanelId)
        guard agentLifecycleStatesByPanelId[targetPanelId]?[key] == .needsInput else {
            // The ordered Running observation is still a tombstone. Recording
            // it prevents a delayed lower-revision permission event from
            // changing the visible state after this hook returns.
            return true
        }
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = .running
        recordAgentLifecycleChange(panelId: targetPanelId)
        reconcileAgentStatuses(panelId: targetPanelId, now: observedAt)
        return true
    }

    private func resetAgentStatusShellReportDedupe(panelId: UUID) {
        TerminalController.shared.socketFastPathState.resetShellActivity(
            workspaceId: id,
            panelId: panelId
        )
    }

    func noteAgentStatusOutputActivity(panelId: UUID, observedAt: Date) {
        let statusKeys = trackedAgentStatusKeys(panelId: panelId)
        guard !statusKeys.isEmpty else { return }
        agentStatusLedger.recordOutput(
            panelId: panelId,
            statusKeys: statusKeys,
            observedAt: observedAt
        )
    }

    func noteAgentStatusTitleActivity(panelId: UUID, observedAt: Date) {
        let statusKeys = trackedAgentStatusKeys(panelId: panelId)
        guard !statusKeys.isEmpty else { return }
        agentStatusLedger.recordTitle(
            panelId: panelId,
            statusKeys: statusKeys,
            observedAt: observedAt
        )
    }

    func noteAgentStatusForegroundAgent(
        statusKey: String?,
        panelId: UUID,
        observedAt: Date
    ) {
        let statusKeys = trackedAgentStatusKeys(panelId: panelId)
        guard !statusKeys.isEmpty else { return }
        agentStatusLedger.recordForegroundAgent(
            statusKey: statusKey,
            panelId: panelId,
            trackedStatusKeys: statusKeys,
            observedAt: observedAt
        )
    }

    func noteAgentStatusShellActivity(
        _ shellActivity: PanelShellActivityState,
        panelId: UUID,
        observedAt: Date = .now
    ) {
        let statusKeys = trackedAgentStatusKeys(panelId: panelId)
        guard !statusKeys.isEmpty else { return }
        agentStatusLedger.recordShellActivity(
            shellActivity,
            panelId: panelId,
            statusKeys: statusKeys,
            observedAt: observedAt
        )
        reconcileAgentStatuses(panelId: panelId, now: observedAt)
    }

    func reconcileAgentStatuses(panelId: UUID? = nil, now: Date = .now) {
        let panelIds: [UUID]
        if let panelId {
            panelIds = panels[panelId] == nil ? [] : [panelId]
        } else {
            panelIds = Array(panels.keys)
        }
        var affectedStatusKeys = Set<String>()
        for panelId in panelIds {
            let statusKeys = trackedAgentStatusKeys(panelId: panelId)
            for statusKey in statusKeys {
                affectedStatusKeys.insert(statusKey)
                agentStatusLedger.seedLifecycleIfMissing(
                    agentLifecycleStatesByPanelId[panelId]?[statusKey],
                    panelId: panelId,
                    statusKey: statusKey
                )
                let evidence = agentStatusLedger.evidence(
                    panelId: panelId,
                    statusKey: statusKey,
                    shellActivity: panelShellActivityStates[panelId] ?? .unknown
                )
                let resolution = AgentStatusReconciler().resolve(
                    evidence: evidence,
                    statusKey: statusKey,
                    hasLiveRuntime: hasLiveAgentRuntime(statusKey: statusKey, panelId: panelId),
                    now: now
                )
                agentStatusLedger.setResolution(
                    resolution,
                    panelId: panelId,
                    statusKey: statusKey
                )
                if let resolution {
                    applyDerivedAgentLifecycle(
                        resolution.lifecycle,
                        statusKey: statusKey,
                        panelId: panelId
                    )
                }
            }
        }
        for statusKey in affectedStatusKeys {
            applyAggregateAgentStatusProjection(statusKey: statusKey, now: now)
        }
    }

    func agentStatusForegroundProbe() -> (
        foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity],
        rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: Set<String>]],
        panelIds: Set<UUID>
    ) {
        var foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity] = [:]
        var rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: Set<String>]] = [:]
        var panelIds = Set<UUID>()
        for panelId in panels.keys {
            let statusKeys = trackedAgentStatusKeys(panelId: panelId)
            guard !statusKeys.isEmpty else { continue }
            panelIds.insert(panelId)
            if let identity = agentStatusForegroundProcessIdentity(panelId: panelId) {
                foregroundProcessIdentities[panelId] = identity
            }
            let rootStatusKeys = liveAgentStatusRootStatusKeys(panelId: panelId)
            if !rootStatusKeys.isEmpty {
                rootStatusKeysByPanelId[panelId] = rootStatusKeys
            }
        }
        return (foregroundProcessIdentities, rootStatusKeysByPanelId, panelIds)
    }

    func agentStatusForegroundProbeIsCurrent(
        panelId: UUID,
        foregroundProcessIdentity: AgentPIDProcessIdentity?,
        rootStatusKeys: [AgentPIDProcessIdentity: Set<String>]
    ) -> Bool {
        guard panels[panelId] != nil,
              agentStatusForegroundProcessIdentity(panelId: panelId) == foregroundProcessIdentity else {
            return false
        }
        return liveAgentStatusRootStatusKeys(panelId: panelId) == rootStatusKeys
    }

    func trackedAgentStatusKeys(panelId: UUID) -> Set<String> {
        Set((agentPIDKeysByPanelId[panelId] ?? []).compactMap { pidKey in
            let statusKey = agentStatusKey(forAgentPIDKey: pidKey)
            return AgentHibernationLifecycleStatusKeys.isAllowed(statusKey) ? statusKey : nil
        })
    }

    private func hasLiveAgentRuntime(statusKey: String, panelId: UUID) -> Bool {
        (agentPIDKeysByPanelId[panelId] ?? []).contains { pidKey in
            guard agentStatusKey(forAgentPIDKey: pidKey) == statusKey,
                  let pid = agentPIDs[pidKey] else { return false }
            return isRecordedAgentPIDLive(key: pidKey, pid: pid)
        }
    }

    private func agentStatusRuntimeIsCurrent(
        pidKey: String,
        pid: Int,
        pidNamespace: AgentStatusPIDNamespace? = nil,
        runtimeProcessIdentity: AgentPIDProcessIdentity? = nil,
        panelId: UUID
    ) -> Bool {
        guard let runtimePID = pid_t(exactly: pid) else { return false }
        let recordedNamespace = agentPIDNamespacesByKey[pidKey] ?? .local
        if let pidNamespace, pidNamespace != recordedNamespace { return false }
        if recordedNamespace == .local,
           let runtimeProcessIdentity,
           agentPIDProcessIdentitiesByKey[pidKey] != runtimeProcessIdentity {
            return false
        }
        return panels[panelId] != nil &&
            agentPIDKeysByPanelId[panelId]?.contains(pidKey) == true &&
            agentPIDs[pidKey] == runtimePID &&
            isRecordedAgentPIDLive(key: pidKey, pid: runtimePID)
    }

    private func agentStatusForegroundProcessIdentity(
        panelId: UUID
    ) -> AgentPIDProcessIdentity? {
        guard let foregroundPID = terminalPanel(for: panelId)?.surface.foregroundProcessID() else {
            return nil
        }
        return AgentPIDProcessIdentity(pid: pid_t(foregroundPID))
    }

    private func liveAgentStatusRootStatusKeys(
        panelId: UUID
    ) -> [AgentPIDProcessIdentity: Set<String>] {
        var rootStatusKeys: [AgentPIDProcessIdentity: Set<String>] = [:]
        for pidKey in agentPIDKeysByPanelId[panelId] ?? [] {
            let statusKey = agentStatusKey(forAgentPIDKey: pidKey)
            guard AgentHibernationLifecycleStatusKeys.isAllowed(statusKey),
                  (agentPIDNamespacesByKey[pidKey] ?? .local) == .local,
                  let pid = agentPIDs[pidKey],
                  pid > 0,
                  let identity = agentPIDProcessIdentitiesByKey[pidKey],
                  identity.pid == pid,
                  AgentPIDProcessIdentity(pid: pid) == identity else {
                continue
            }
            rootStatusKeys[identity, default: []].insert(statusKey)
        }
        return rootStatusKeys
    }

    private func applyDerivedAgentLifecycle(
        _ lifecycle: AgentHibernationLifecycleState,
        statusKey: String,
        panelId: UUID
    ) {
        guard agentLifecycleStatesByPanelId[panelId]?[statusKey] != lifecycle else { return }
        agentLifecycleStatesByPanelId[panelId, default: [:]][statusKey] = lifecycle
        recordAgentLifecycleChange(panelId: panelId)
    }

    private func applyAggregateAgentStatusProjection(statusKey: String, now: Date) {
        guard let resolution = aggregateAgentStatusResolution(statusKey: statusKey) else { return }
        guard let projectedEntry = canonicalStatusEntry(
            statusKey: statusKey,
            lifecycle: resolution.lifecycle,
            timestamp: now
        ) else {
            statusEntries.removeValue(forKey: statusKey)
            return
        }
        if let current = statusEntries[statusKey],
           statusEntry(current, represents: resolution.lifecycle) {
            return
        }
        statusEntries[statusKey] = projectedEntry
    }

    private func aggregateAgentStatusResolution(statusKey: String) -> AgentStatusResolution? {
        let resolutions = panels.keys.compactMap {
            agentStatusLedger.resolutionsByPanelId[$0]?[statusKey]
        }
        return resolutions.max { lhs, rhs in
            let lhsRank = aggregateRank(lhs.lifecycle)
            let rhsRank = aggregateRank(rhs.lifecycle)
            return lhsRank == rhsRank ? lhs.confidence.rawValue < rhs.confidence.rawValue : lhsRank < rhsRank
        }
    }

    private func aggregateRank(_ lifecycle: AgentHibernationLifecycleState) -> Int {
        switch lifecycle {
        case .needsInput: return 4
        case .running: return 3
        case .unknown: return 2
        case .idle: return 1
        }
    }

    private func statusEntry(
        _ entry: SidebarStatusEntry,
        represents lifecycle: AgentHibernationLifecycleState
    ) -> Bool {
        switch lifecycle {
        case .running:
            return entry.icon == "bolt.fill"
        case .needsInput:
            return entry.icon == "bell.fill" || entry.icon == "exclamationmark.triangle.fill"
        case .idle:
            return entry.icon == "pause.circle.fill"
        case .unknown:
            return false
        }
    }

    private func canonicalStatusEntry(
        statusKey: String,
        lifecycle: AgentHibernationLifecycleState,
        timestamp: Date
    ) -> SidebarStatusEntry? {
        switch lifecycle {
        case .running:
            return SidebarStatusEntry(
                key: statusKey,
                value: String(localized: "agent.generic.status.running", defaultValue: "Running"),
                icon: "bolt.fill",
                color: "#4C8DFF",
                timestamp: timestamp
            )
        case .needsInput:
            return SidebarStatusEntry(
                key: statusKey,
                value: String(localized: "feed.status.needsInput", defaultValue: "Needs input"),
                icon: "bell.fill",
                color: "#4C8DFF",
                priority: 100,
                timestamp: timestamp
            )
        case .idle:
            return SidebarStatusEntry(
                key: statusKey,
                value: String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle"),
                icon: "pause.circle.fill",
                color: "#8E8E93",
                timestamp: timestamp
            )
        case .unknown:
            return nil
        }
    }
}
