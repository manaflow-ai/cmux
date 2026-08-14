import CmuxSidebar
import Foundation

extension Workspace {
    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] {
        let visibleStructuredStatusKeys = visibleStructuredAgentStatusKeysByPanel()
        return statusEntries.values.filter { entry in
            shouldDisplaySidebarStatusEntry(entry, visibleStructuredStatusKeys: visibleStructuredStatusKeys)
        }
    }

    private func shouldDisplaySidebarStatusEntry(
        _ entry: SidebarStatusEntry,
        visibleStructuredStatusKeys: Set<String>
    ) -> Bool {
        guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key) else {
            return true
        }
        return visibleStructuredStatusKeys.contains(entry.key)
    }

    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            statusKeysByPanelId[panelId, default: []].insert(statusKey)
        }
        for (panelId, keys) in Self.agentStatusKeysAdmittedByLifecycle(
            lifecycleStatesByPanelId: agentLifecycleStatesByPanelId,
            livePanelIds: Set(panels.keys),
            storedStatusKeys: Set(statusEntries.keys)
        ) {
            statusKeysByPanelId[panelId, default: []].formUnion(keys)
        }
        var visibleStatusKeys = Set<String>()
        for statusKeys in statusKeysByPanelId.values {
            let winningEntry = statusKeys.compactMap { statusEntries[$0] }.max {
                isSidebarStatusEntryLessCurrent($0, than: $1)
            }
            if let winningEntry {
                visibleStatusKeys.insert(winningEntry.key)
            }
        }

        for key in agentPIDs.keys where agentPIDPanelIdsByKey[key] == nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            visibleStatusKeys.insert(statusKey)
        }

        return visibleStatusKeys
    }

    /// Admits reserved agent status keys whose liveness is proven by a
    /// hook-reported lifecycle rather than a recorded process.
    ///
    /// A remote agent has no local process, so no agent PID is ever recorded
    /// for its key and the PID-derived pass can never admit it — its Running
    /// chip would be stored but permanently invisible. Its liveness signal is
    /// the hook-reported lifecycle (the same signal the todo lane trusts for
    /// anyAgentRunning), so a live lifecycle admits the key too. Admitted
    /// keys are grouped per panel and merged into the same per-panel
    /// winner selection as the PID-derived keys, so a pane still shows only
    /// its most current agent chip.
    nonisolated static func agentStatusKeysAdmittedByLifecycle(
        lifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]],
        livePanelIds: Set<UUID>,
        storedStatusKeys: Set<String>
    ) -> [UUID: Set<String>] {
        var admitted: [UUID: Set<String>] = [:]
        for (panelId, lifecycleStates) in lifecycleStatesByPanelId
        where livePanelIds.contains(panelId) {
            for (key, lifecycle) in lifecycleStates {
                guard lifecycle == .running || lifecycle == .needsInput,
                      AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(key),
                      storedStatusKeys.contains(key) else {
                    continue
                }
                admitted[panelId, default: []].insert(key)
            }
        }
        return admitted
    }

    private func isSidebarStatusEntryLessCurrent(
        _ lhs: SidebarStatusEntry,
        than rhs: SidebarStatusEntry
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.key > rhs.key
    }
}
