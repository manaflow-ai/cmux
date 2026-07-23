import Foundation

/// Ordered teardown for agent runtime state shared by socket and internal cleanup paths.
extension Workspace {
    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false,
        refreshPorts: Bool = true
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let lifecyclePanelId = ownedPanelId ?? panelId
        let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
        guard shouldAcceptAgentRuntimeClear(
            statusKey: lifecycleStatusKey,
            panelId: lifecyclePanelId,
            agentEventTime: agentEventTime,
            enforceOrdering: enforceAgentEventOrdering
        ) else { return false }
        recordAcceptedAgentRuntimeClear(
            statusKey: lifecycleStatusKey,
            panelId: lifecyclePanelId,
            agentEventTime: agentEventTime
        )
        let statusKeyToClear = clearStatus ? lifecycleStatusKey : nil

        var didChange = false
        if agentPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if agentPIDProcessIdentitiesByKey.removeValue(forKey: key) != nil {
            didChange = true
        }
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let changedPanelId = lifecyclePanelId, didChange {
            AgentHibernationController.shared.recordAgentProcessChange(
                workspaceId: id,
                panelId: changedPanelId
            )
        }
        if let lifecyclePanelId,
           clearAgentLifecycle(key: lifecycleStatusKey, panelId: lifecyclePanelId) {
            didChange = true
        }
        if let statusKeyToClear,
           !hasAgentRuntime(forStatusKey: statusKeyToClear),
           statusEntries.removeValue(forKey: statusKeyToClear) != nil {
            didChange = true
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    private func shouldAcceptAgentRuntimeClear(
        statusKey: String,
        panelId: UUID?,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool
    ) -> Bool {
        guard enforceOrdering, let panelId else { return true }
        let lifecycleEventTime = agentLifecycleEventTimesByPanelId[panelId]?[statusKey]
        let statusEventTime = statusEntries[statusKey].flatMap { entry in
            entry.agentOwnerPanelID == nil || entry.agentOwnerPanelID == panelId
                ? entry.agentEventTime
                : nil
        }
        guard let orderingWatermark = [lifecycleEventTime, statusEventTime]
            .compactMap({ $0 })
            .max() else {
            return true
        }
        guard let agentEventTime else { return false }
        return agentEventTime >= orderingWatermark
    }

    private func recordAcceptedAgentRuntimeClear(
        statusKey: String,
        panelId: UUID?,
        agentEventTime: TimeInterval?
    ) {
        guard let panelId, let agentEventTime else { return }
        if let current = agentLifecycleEventTimesByPanelId[panelId]?[statusKey],
           agentEventTime <= current {
            return
        }
        agentLifecycleEventTimesByPanelId[panelId, default: [:]][statusKey] = agentEventTime
    }
}
