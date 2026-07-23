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
        guard acceptAgentRuntimeMutation(
            statusKey: lifecycleStatusKey,
            panelId: lifecyclePanelId,
            agentEventTime: agentEventTime,
            enforceOrdering: enforceAgentEventOrdering
        ) else { return false }
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
           let statusEntry = statusEntries[statusKeyToClear],
           statusEntry.agentOwnerPanelID == nil || statusEntry.agentOwnerPanelID == lifecyclePanelId,
           statusEntries.removeValue(forKey: statusKeyToClear) != nil {
            didChange = true
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    /// Applies the shared per-agent, per-pane event watermark used by status,
    /// lifecycle, PID, notification, and teardown mutations.
    @discardableResult
    func acceptAgentRuntimeMutation(
        statusKey: String,
        panelId: UUID?,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool,
        enforceStructuredAgentReplacementOrdering: Bool = false
    ) -> Bool {
        guard enforceOrdering, let panelId else { return true }
        let lifecycleEventTime = agentLifecycleEventTimesByPanelId[panelId]?[statusKey]
        let statusEventTime = statusEntries[statusKey].flatMap { entry in
            entry.agentOwnerPanelID == nil || entry.agentOwnerPanelID == panelId
                ? entry.agentEventTime
                : nil
        }
        if enforceStructuredAgentReplacementOrdering,
           let replacementWatermark = (agentLifecycleEventTimesByPanelId[panelId] ?? [:])
               .filter { key, _ in
                   key != statusKey && AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(key)
               }
               .values
               .max() {
            guard let agentEventTime, agentEventTime > replacementWatermark else {
                return false
            }
        }
        if let orderingWatermark = [lifecycleEventTime, statusEventTime]
            .compactMap({ $0 })
            .max() {
            guard let agentEventTime, agentEventTime >= orderingWatermark else {
                return false
            }
        }
        if let agentEventTime {
            if let current = agentLifecycleEventTimesByPanelId[panelId]?[statusKey] {
                if agentEventTime > current {
                    agentLifecycleEventTimesByPanelId[panelId, default: [:]][statusKey] = agentEventTime
                }
            } else {
                agentLifecycleEventTimesByPanelId[panelId, default: [:]][statusKey] = agentEventTime
            }
        }
        return true
    }
}
