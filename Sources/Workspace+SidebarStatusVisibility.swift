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

    /// Structured agent status keys that may show: the newest per live panel
    /// among the agents that panel owns. Local agents own a panel through a
    /// registered PID; relay-host agents have no local PID, so on relay-backed
    /// workspaces the hook-reported lifecycle on a live panel is the ownership
    /// evidence instead.
    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        if showsRelayHostAgentStatus {
            for (panelId, lifecycleStates) in agentLifecycleStatesByPanelId
            where panels[panelId] != nil {
                for statusKey in lifecycleStates.keys
                where AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey)
                    && statusEntries[statusKey] != nil {
                    statusKeysByPanelId[panelId, default: []].insert(statusKey)
                }
            }
        }
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            statusKeysByPanelId[panelId, default: []].insert(statusKey)
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

    /// Relay-host agents report state only through relayed hooks. cmux-tui SSH
    /// workspaces publish their own remote status keys instead.
    var showsRelayHostAgentStatus: Bool {
        (remoteConfiguration?.relayPort ?? 0) > 0 && !usesSSHTui
    }

    /// Drops relay-host agent status and lifecycle once the relay is down: no
    /// local PID can prove the remote agent survived, and a hook that would
    /// clear it can no longer arrive. The next relayed hook reports afresh.
    /// Keys a local agent PID still owns are left alone.
    func clearRelayHostAgentStatus() {
        guard showsRelayHostAgentStatus else { return }
        let localAgentKeys = Set(agentPIDs.keys)
        for statusKey in AgentHibernationLifecycleStatusKeys.allowedStatusKeys
            where !localAgentKeys.contains(statusKey) {
            if statusEntries[statusKey] != nil {
                statusEntries.removeValue(forKey: statusKey)
            }
            _ = clearAgentLifecycle(key: statusKey)
        }
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
