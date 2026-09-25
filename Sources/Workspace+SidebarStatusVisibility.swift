import CmuxSidebar
import Foundation

extension Workspace {
    private static let feedAttentionStatusKeyPrefix = "cmux.feed.attention:"

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
        if Self.feedAttentionAgentStatusKey(for: entry.key) != nil {
            return visibleStructuredStatusKeys.contains(entry.key)
        }
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

        // Feed keeps its blocking-decision status in a separate namespace so
        // it cannot overwrite the agent's own lifecycle/status slot. For the
        // sidebar, both keys still describe the same agent on this panel and
        // must compete for one displayed row.
        for (panelId, lifecycleStates) in agentLifecycleStatesByPanelId
        where panels[panelId] != nil {
            for (key, lifecycle) in lifecycleStates {
                guard lifecycle == .needsInput,
                      Self.feedAttentionAgentStatusKey(for: key) != nil,
                      statusEntries[key] != nil else {
                    continue
                }
                statusKeysByPanelId[panelId, default: []].insert(key)
            }
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

    private static func feedAttentionAgentStatusKey(for statusKey: String) -> String? {
        guard statusKey.hasPrefix(feedAttentionStatusKeyPrefix) else { return nil }
        let agentStatusKey = String(statusKey.dropFirst(feedAttentionStatusKeyPrefix.count))
        return agentStatusKey.isEmpty ? nil : agentStatusKey
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
