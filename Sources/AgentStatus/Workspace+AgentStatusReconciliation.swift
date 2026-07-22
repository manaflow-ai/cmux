import CmuxSidebar
import Foundation

extension Workspace {
    private var agentStatusLedger: AgentStatusRuntimeLedger {
        sidebarAgentRuntimeObservation.agentStatusLedger
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
        guard AgentHibernationLifecycleStatusKeys.isAllowed(key) else { return }
        let observedAt = Date.now
        agentStatusLedger.recordLifecycle(
            lifecycle,
            panelId: targetPanelId,
            statusKey: key,
            observedAt: observedAt
        )
        reconcileAgentStatuses(panelId: targetPanelId, now: observedAt)
    }

    func noteAgentStatusHookSignal(
        _ signal: AgentStatusHookEventSignal,
        panelId: UUID?
    ) {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return }
        guard agentStatusLedger.recordLifecycle(
            signal.lifecycle,
            panelId: targetPanelId,
            statusKey: signal.statusKey,
            observedAt: signal.observedAt
        ) else { return }
        reconcileAgentStatuses(panelId: targetPanelId, now: signal.observedAt)
    }

    func noteAgentStatusOutputActivity(panelId: UUID, observedAt: Date) {
        let statusKeys = trackedAgentStatusKeys(panelId: panelId)
        guard !statusKeys.isEmpty else { return }
        agentStatusLedger.recordOutput(
            panelId: panelId,
            statusKeys: statusKeys,
            observedAt: observedAt
        )
        reconcileAgentStatuses(panelId: panelId, now: observedAt)
    }

    func noteAgentStatusTitleActivity(panelId: UUID, observedAt: Date) {
        let statusKeys = trackedAgentStatusKeys(panelId: panelId)
        guard !statusKeys.isEmpty else { return }
        agentStatusLedger.recordTitle(
            panelId: panelId,
            statusKeys: statusKeys,
            observedAt: observedAt
        )
        reconcileAgentStatuses(panelId: panelId, now: observedAt)
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
                    statusKey: statusKey,
                    observedAt: statusEntries[statusKey]?.timestamp
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
        foregroundPIDs: [UUID: Int],
        rootStatusKeysByPanelId: [UUID: [Int: String]],
        panelIds: Set<UUID>
    ) {
        var foregroundPIDs: [UUID: Int] = [:]
        var rootStatusKeysByPanelId: [UUID: [Int: String]] = [:]
        var panelIds = Set<UUID>()
        for panelId in panels.keys {
            let statusKeys = trackedAgentStatusKeys(panelId: panelId)
            guard !statusKeys.isEmpty else { continue }
            panelIds.insert(panelId)
            if let foregroundPID = terminalPanel(for: panelId)?.surface.foregroundProcessID() {
                foregroundPIDs[panelId] = foregroundPID
            }
            for pidKey in agentPIDKeysByPanelId[panelId] ?? [] {
                guard let pid = agentPIDs[pidKey], pid > 0 else { continue }
                rootStatusKeysByPanelId[panelId, default: [:]][Int(pid)] = agentStatusKey(
                    forAgentPIDKey: pidKey
                )
            }
        }
        return (foregroundPIDs, rootStatusKeysByPanelId, panelIds)
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
        if let current = statusEntries[statusKey],
           statusEntry(current, represents: resolution.lifecycle) {
            return
        }
        statusEntries[statusKey] = canonicalStatusEntry(
            statusKey: statusKey,
            lifecycle: resolution.lifecycle,
            timestamp: now
        )
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
            return entry.icon == "questionmark.circle"
        }
    }

    private func canonicalStatusEntry(
        statusKey: String,
        lifecycle: AgentHibernationLifecycleState,
        timestamp: Date
    ) -> SidebarStatusEntry {
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
            return SidebarStatusEntry(
                key: statusKey,
                value: String(localized: "agent.generic.status.uncertain", defaultValue: "Status uncertain"),
                icon: "questionmark.circle",
                color: "#8E8E93",
                timestamp: timestamp
            )
        }
    }
}
