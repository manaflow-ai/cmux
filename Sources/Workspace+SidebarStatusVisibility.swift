import CmuxSidebar
import Foundation

extension Workspace {
    /// The workspace row is an aggregate of every pane: each visible key shows
    /// its most urgent pane's entry (see `mostUrgentPanelStatusEntry`), not
    /// whichever pane wrote last or the focused one.
    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] {
        let visibleStructuredStatusKeys = visibleStructuredAgentStatusKeysByPanel()
        return statusEntries.values.compactMap { entry in
            guard shouldDisplaySidebarStatusEntry(entry, visibleStructuredStatusKeys: visibleStructuredStatusKeys) else {
                return nil
            }
            return mostUrgentPanelStatusEntry(forKey: entry.key) ?? entry
        }
    }

    /// Keys with at least one live pane waiting on the person; the row sorts
    /// them ahead of other entries of the same priority.
    func sidebarStatusKeysNeedingInput() -> Set<String> {
        var keys = Set<String>()
        for (panelId, lifecycleStates) in agentLifecycleStatesByPanelId where panels[panelId] != nil {
            for (key, lifecycle) in lifecycleStates where lifecycle == .needsInput {
                keys.insert(key)
            }
        }
        return keys
    }

    /// A pane's own last-reported entry for `key`, while the workspace still
    /// shows that key at all.
    func agentStatusEntry(key: String, panelId: UUID) -> SidebarStatusEntry? {
        guard statusEntries[key] != nil else { return nil }
        return agentStatusEntriesByPanelId[panelId]?[key]
    }

    func setStatusEntry(_ entry: SidebarStatusEntry, key: String, panelId: UUID?) {
        statusEntries[key] = entry
        if let panelId, panels[panelId] != nil {
            agentStatusEntriesByPanelId[panelId, default: [:]][key] = entry
        }
    }

    func clearStatusEntry(key: String, panelId: UUID?) {
        removeStatusEntry(forKey: key)
    }

    /// Removes the key and every pane's copy of it, so a later report for the
    /// key never revives an older pane's text.
    @discardableResult
    func removeStatusEntry(forKey key: String) -> Bool {
        for panelId in Array(agentStatusEntriesByPanelId.keys) {
            removePanelStatusEntry(key: key, panelId: panelId)
        }
        return statusEntries.removeValue(forKey: key) != nil
    }

    /// Drops one pane's copy, e.g. when its agent lifecycle for the key ends;
    /// the row then falls back to the workspace entry for that pane.
    func removePanelStatusEntry(key: String, panelId: UUID) {
        agentStatusEntriesByPanelId[panelId]?.removeValue(forKey: key)
        if agentStatusEntriesByPanelId[panelId]?.isEmpty == true {
            agentStatusEntriesByPanelId.removeValue(forKey: panelId)
        }
    }

    /// Several panes can report the same agent key (two Claude panes share
    /// `claude_code`). The pane that most needs the person wins: needs input,
    /// then running, then unknown, then idle; the newest report breaks ties.
    /// Only live panes that still own the agent (a lifecycle state or an agent
    /// PID for the key) count, so an ended pane's last report never lingers.
    /// Nil when no pane-scoped report exists; callers fall back to the
    /// workspace entry.
    func mostUrgentPanelStatusEntry(forKey key: String) -> SidebarStatusEntry? {
        var winner: (rank: Int, entry: SidebarStatusEntry)?
        for (panelId, entries) in agentStatusEntriesByPanelId where panels[panelId] != nil {
            guard let entry = entries[key], panelOwnsAgentStatus(key: key, panelId: panelId) else { continue }
            let rank = Self.sidebarStatusUrgencyRank(agentLifecycleStatesByPanelId[panelId]?[key])
            if let current = winner, (current.rank, current.entry.timestamp) >= (rank, entry.timestamp) {
                continue
            }
            winner = (rank, entry)
        }
        return winner?.entry
    }

    private func panelOwnsAgentStatus(key: String, panelId: UUID) -> Bool {
        if agentLifecycleStatesByPanelId[panelId]?[key] != nil { return true }
        return agentPIDKeysByPanelId[panelId]?.contains { agentStatusKey(forAgentPIDKey: $0) == key } ?? false
    }

    static func sidebarStatusUrgencyRank(_ lifecycle: AgentHibernationLifecycleState?) -> Int {
        switch lifecycle {
        case .running: 4
        case .backgroundWorkPending: 3
        case .needsInput: 2
        case .unknown, nil: 1
        case .idle: 0
        }
    }

    func sidebarStatusUrgencyRank(forKey key: String) -> Int {
        agentLifecycleStatesByPanelId.values
            .compactMap { Self.sidebarStatusUrgencyRank($0[key]) }
            .max() ?? 0
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
            removeStatusEntry(forKey: statusKey)
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

extension Workspace {
    /// Returns the existing sidebar agent identity when this panel is in an
    /// active turn. Close warnings use this same ownership and lifecycle
    /// evidence rather than introducing another process detector.
    func activeAgentCloseWarningInfo(panelId: UUID) -> (displayName: String)? {
        guard panels[panelId] != nil else { return nil }
        var statusKeys = Set<String>()
        for key in agentPIDKeysByPanelId[panelId, default: []] {
            statusKeys.insert(agentStatusKey(forAgentPIDKey: key))
        }
        statusKeys.formUnion(
            agentLifecycleStatesByPanelId[panelId, default: [:]].keys
                .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0) }
        )
        for (key, entry) in agentStatusEntriesByPanelId[panelId, default: [:]]
        where AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(key) {
            statusKeys.insert(key)
            if entry.workState == .running || entry.workState == .subagents {
                return (SidebarCompactStatusGlyph.agentDisplayName(forStatusKey: key))
            }
        }
        for key in statusKeys {
            if agentLifecycleStatesByPanelId[panelId]?[key] == .running {
                return (SidebarCompactStatusGlyph.agentDisplayName(forStatusKey: key))
            }
            if let entry = agentStatusEntriesByPanelId[panelId]?[key],
               entry.workState == .running || entry.workState == .subagents {
                return (SidebarCompactStatusGlyph.agentDisplayName(forStatusKey: key))
            }
        }
        return nil
    }
}
