import CmuxSidebar
import Foundation

/// Immutable per-pane agent status row consumed by the sidebar (a value
/// snapshot only, per the sidebar list snapshot-boundary rule).
struct SidebarAgentStatusRow: Equatable, Identifiable {
    let panelId: UUID
    let statusKey: String
    let value: String?
    let icon: String?
    let color: String?
    let url: URL?
    /// How `value` renders (markdown vs plain); tied to `value`'s source entry.
    let format: SidebarMetadataFormat
    let lifecycle: AgentHibernationLifecycleState?
    let paneLabel: String?
    let priority: Int
    let timestamp: Date

    var id: String { "\(panelId.uuidString)|\(statusKey)" }
}

/// Panel-scoped structured agent status: storage, visibility filtering, and
/// the per-agent sidebar row projection. Lifecycle bookkeeping (PID ownership,
/// transfer, cleanup) stays in `Workspace+PanelLifecycle.swift`.
extension Workspace {
    var statusEntriesByPanelId: [UUID: [String: SidebarStatusEntry]] {
        get { sidebarAgentRuntimeObservation.statusEntriesByPanelId }
        set { sidebarAgentRuntimeObservation.setStatusEntriesByPanelId(newValue) }
    }

    /// Records the panel-scoped copy of a structured agent status report, so
    /// each agent pane keeps its own row even when several agents of the same
    /// type share the workspace (the workspace-level `statusEntries` slot is
    /// last-write-wins per agent type). Identical repeated reports are dropped
    /// (ignoring the timestamp) so agent heartbeats with no visible change do
    /// not invalidate the sidebar snapshot.
    func recordPanelStatusEntry(_ entry: SidebarStatusEntry, panelId: UUID) {
        guard Self.structuredAgentHookStatusKeys.contains(entry.key) else { return }
        guard TerminalController.shouldReplaceStatusEntry(
            current: statusEntriesByPanelId[panelId]?[entry.key],
            key: entry.key,
            value: entry.value,
            icon: entry.icon,
            color: entry.color,
            url: entry.url,
            priority: entry.priority,
            format: entry.format
        ) else { return }
        statusEntriesByPanelId[panelId, default: [:]][entry.key] = entry
    }

    @discardableResult
    func clearPanelStatusEntry(statusKey: String, panelId: UUID) -> Bool {
        guard var entries = statusEntriesByPanelId[panelId],
              entries.removeValue(forKey: statusKey) != nil else {
            return false
        }
        if entries.isEmpty {
            statusEntriesByPanelId.removeValue(forKey: panelId)
        } else {
            statusEntriesByPanelId[panelId] = entries
        }
        return true
    }

    @discardableResult
    func clearPanelStatusEntries(statusKey: String) -> Bool {
        var didChange = false
        for panelId in statusEntriesByPanelId.keys where statusEntriesByPanelId[panelId]?[statusKey] != nil {
            if clearPanelStatusEntry(statusKey: statusKey, panelId: panelId) {
                didChange = true
            }
        }
        return didChange
    }

    /// Every panel that plausibly owns `statusKey`: panels with a live agent
    /// PID mapping to that key plus panels holding a panel-scoped entry for
    /// it. Used to decide whether the ambiguous workspace-level last-write-wins
    /// entry can be attributed to a single pane.
    func panelsOwningAgentStatusKey(_ statusKey: String) -> Set<UUID> {
        var owners: Set<UUID> = []
        for (key, ownerPanelId) in agentPIDPanelIdsByKey
        where agentStatusKey(forAgentPIDKey: key) == statusKey {
            owners.insert(ownerPanelId)
        }
        for (ownerPanelId, entries) in statusEntriesByPanelId where entries[statusKey] != nil {
            owners.insert(ownerPanelId)
        }
        return owners
    }

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
        guard Self.structuredAgentHookStatusKeys.contains(entry.key) else {
            return true
        }
        return visibleStructuredStatusKeys.contains(entry.key)
    }

    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
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
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            visibleStatusKeys.insert(statusKey)
        }

        return visibleStatusKeys
    }

    /// One sidebar row per live agent pane, so several agents in one workspace
    /// never collapse into a single last-write-wins pill. Candidate
    /// (panel, statusKey) pairs are the UNION of recorded agent PID ownership
    /// and live panels holding a panel-scoped structured entry: Claude-style
    /// hooks share one bare PID key per agent type across panes (ownership
    /// migrates to the last reporter), so the panel-scoped entry must keep a
    /// pane's row alive independently. Stale entries stay bounded because
    /// `clear_status`, `clearAgentPID(clearStatus: true)`, and pane close all
    /// drop panel-scoped entries. A panel-scoped report wins; the
    /// workspace-level entry is only trusted when a single pane owns that
    /// status key; otherwise the per-panel lifecycle drives the row.
    func sidebarAgentStatusRows() -> [SidebarAgentStatusRow] {
        var statusKeysByPanel: [UUID: Set<String>] = [:]
        for (key, panelId) in agentPIDPanelIdsByKey where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey) else { continue }
            statusKeysByPanel[panelId, default: []].insert(statusKey)
        }
        for (panelId, entries) in statusEntriesByPanelId where panels[panelId] != nil {
            for statusKey in entries.keys where Self.structuredAgentHookStatusKeys.contains(statusKey) {
                statusKeysByPanel[panelId, default: []].insert(statusKey)
            }
        }

        var chosenByPanel: [(panelId: UUID, statusKey: String, entry: SidebarStatusEntry?)] = []
        for (panelId, statusKeys) in statusKeysByPanel {
            let candidates = statusKeys.map { ($0, statusEntriesByPanelId[panelId]?[$0]) }
            let chosen = candidates.max { lhs, rhs in
                switch (lhs.1, rhs.1) {
                case let (lhsEntry?, rhsEntry?):
                    return isSidebarStatusEntryLessCurrent(lhsEntry, than: rhsEntry)
                case (nil, .some):
                    return true
                case (.some, nil):
                    return false
                case (nil, nil):
                    return lhs.0 > rhs.0
                }
            }
            if let chosen {
                chosenByPanel.append((panelId: panelId, statusKey: chosen.0, entry: chosen.1))
            }
        }

        var panelCountByStatusKey: [String: Int] = [:]
        for item in chosenByPanel {
            panelCountByStatusKey[item.statusKey, default: 0] += 1
        }

        let includePaneLabels = chosenByPanel.count > 1
        let rows = chosenByPanel.map { item -> SidebarAgentStatusRow in
            let workspaceEntry = statusEntries[item.statusKey]
            let soleOwner = panelCountByStatusKey[item.statusKey] == 1
            let entry = item.entry ?? (soleOwner ? workspaceEntry : nil)
            return SidebarAgentStatusRow(
                panelId: item.panelId,
                statusKey: item.statusKey,
                value: entry?.value,
                icon: entry?.icon ?? (soleOwner ? workspaceEntry?.icon : nil),
                color: entry?.color ?? (soleOwner ? workspaceEntry?.color : nil),
                url: entry?.url,
                format: entry?.format ?? .plain,
                lifecycle: agentLifecycleStatesByPanelId[item.panelId]?[item.statusKey],
                paneLabel: includePaneLabels ? agentStatusRowPaneLabel(panelId: item.panelId) : nil,
                // No workspace fallback here: when the pane is not the sole
                // owner, the last-write-wins workspace entry's freshness must
                // not influence this row's sort position either.
                priority: entry?.priority ?? 0,
                timestamp: entry?.timestamp ?? .distantPast
            )
        }
        return rows.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    private func agentStatusRowPaneLabel(panelId: UUID) -> String? {
        let candidates = [
            panelCustomTitles[panelId],
            panelDirectoryDisplayLabels[panelId],
            panelTitles[panelId],
        ]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
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
