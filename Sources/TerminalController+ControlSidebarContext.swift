import CmuxControlSocket
import Foundation
import CmuxSidebar

/// The live-app half of the v1 sidebar metadata commands (`set_status` /
/// `report_meta` / `report_meta_block` / agent PID + lifecycle / `log` /
/// `set_progress` and their clears + listings): the exact mutation/read bodies
/// the former `TerminalController` v1 handlers ran, minus the parsing and
/// reply formatting that moved into `ControlCommandCoordinator`.
extension TerminalController: ControlSidebarContext {
    // MARK: - Availability

    func controlSidebarTabManagerAvailable() -> Bool {
        tabManager != nil
    }

    // MARK: - Scheduled sidebar mutations (status / agent / blocks)

    func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?
    ) {
        let appFormat = SidebarMetadataFormat(rawValue: format.rawValue) ?? .plain
        controlSidebarScheduleMutation(target: target) { _, tab in
            if let panelId = panelID, !tab.panels.keys.contains(panelId) {
                return
            }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: appFormat
            ) else {
                // Still update PID tracking even if the status display hasn't changed.
                if let pid {
                    tab.recordAgentPID(key: key, pid: pid, panelId: panelID)
                }
                return
            }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: appFormat,
                timestamp: Date()
            )
            if let pid {
                tab.recordAgentPID(key: key, pid: pid, panelId: panelID)
            }
        }
    }

    func controlSidebarScheduleStatusClear(target: ControlSidebarTabTarget, key: String) {
        controlSidebarScheduleMutation(target: target) { _, tab in
            _ = tab.statusEntries.removeValue(forKey: key)
            tab.clearAgentPID(key: key)
        }
    }

    func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?
    ) {
        controlSidebarScheduleMutation(target: target) { _, tab in
            if let panelId = panelID, !tab.panels.keys.contains(panelId) {
                return
            }
            let didReplaceAgentRuntime = tab.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelID
            )
            if didReplaceAgentRuntime, let panelId = panelID {
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tab.id,
                    surfaceId: panelId,
                    discardQueuedNotifications: false
                )
            }
        }
    }

    func controlSidebarParseAgentLifecycle(_ raw: String) -> String? {
        AgentHibernationLifecycleState.parseCLIValue(raw)?.rawValue
    }

    func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        if AgentHibernationLifecycleStatusKeys.isAllowed(key) {
            return true
        }
        guard let tab = controlSidebarResolveMutationTab(target),
              CmuxVaultAgentRegistration.isValidID(key) else {
            return false
        }
        let registry = CmuxVaultAgentRegistry.load(
            workingDirectory: controlSidebarAgentLifecycleRegistryWorkingDirectory(tab: tab, panelId: panelID)
        )
        return registry.registration(id: key) != nil
    }

    /// The byte-faithful twin of the deleted file-private
    /// `agentLifecycleRegistryWorkingDirectory(tab:panelId:)`.
    private func controlSidebarAgentLifecycleRegistryWorkingDirectory(tab: Workspace, panelId: UUID?) -> String? {
        let candidates = [
            panelId.flatMap { tab.panelDirectories[$0] },
            tab.focusedPanelId.flatMap { tab.panelDirectories[$0] },
            tab.currentDirectory,
        ]
        return candidates.compactMap(controlSidebarNormalizedOptionValue).first
    }

    /// The byte-faithful twin of the deleted file-private
    /// `normalizedOptionValue(_:)` (trim; empty becomes `nil`).
    private func controlSidebarNormalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?
    ) {
        guard let lifecycle = AgentHibernationLifecycleState(rawValue: lifecycleRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        controlSidebarScheduleMutation(target: target) { _, tab in
            if let panelId = panelID, !tab.panels.keys.contains(panelId) {
                return
            }
            tab.setAgentLifecycle(key: key, panelId: panelID, lifecycle: lifecycle)
        }
    }

    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        func isLoading() -> Bool {
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: tab.agentLifecycleStatesByPanelId
            ) > 0
        }
        let before = isLoading()
        if on {
            // Any panel works for "on" since "off" clears the key from every
            // panel; prefer the focused one so it co-locates with active work.
            if let panelId = tab.focusedPanelId ?? tab.panels.keys.first {
                tab.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
            }
        } else {
            // Clear from ALL panels so the loader turns off regardless of which
            // surface set it on (workspace-scoped, not panel-scoped).
            _ = tab.clearAgentLifecycle(key: key, panelId: nil)
        }
        return ControlSidebarWorkspaceLoadingState(before: before, after: isLoading())
    }

    func controlSidebarSetAgentHibernation(enabled: Bool) {
        AgentHibernationSettings.setValues(enabled: enabled)
    }

    func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool
    ) {
        controlSidebarScheduleMutation(target: target) { _, tab in
            if let panelId = panelID, !tab.panels.keys.contains(panelId) {
                return
            }
            tab.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: clearStatus
            )
        }
    }

    func controlSidebarScheduleMetadataBlockUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        markdown: String,
        priority: Int
    ) {
        controlSidebarScheduleMutation(target: target) { _, tab in
            guard Self.shouldReplaceMetadataBlock(
                current: tab.metadataBlocks[key],
                key: key,
                markdown: markdown,
                priority: priority
            ) else {
                return
            }
            tab.metadataBlocks[key] = SidebarMetadataBlock(
                key: key,
                markdown: markdown,
                priority: priority,
                timestamp: Date()
            )
        }
    }

    // MARK: - Synchronous metadata reads / writes

    func controlSidebarStatusEntries(tabArg: String?) -> [ControlSidebarStatusEntrySnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.sidebarStatusEntriesInDisplayOrder().map(Self.controlSidebarStatusEntrySnapshot)
    }

    /// Converts one app status entry to its Sendable wire snapshot.
    private static func controlSidebarStatusEntrySnapshot(_ entry: SidebarStatusEntry) -> ControlSidebarStatusEntrySnapshot {
        ControlSidebarStatusEntrySnapshot(
            key: entry.key,
            value: entry.value,
            icon: entry.icon,
            color: entry.color,
            urlAbsoluteString: entry.url?.absoluteString,
            priority: entry.priority,
            format: ControlSidebarMetadataFormat(rawValue: entry.format.rawValue) ?? .plain
        )
    }

    func controlSidebarMetadataBlocks(tabArg: String?) -> [ControlSidebarMetadataBlockSnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.sidebarMetadataBlocksInDisplayOrder().map(Self.controlSidebarMetadataBlockSnapshot)
    }

    /// Converts one app metadata block to its Sendable wire snapshot.
    private static func controlSidebarMetadataBlockSnapshot(_ block: SidebarMetadataBlock) -> ControlSidebarMetadataBlockSnapshot {
        ControlSidebarMetadataBlockSnapshot(
            key: block.key,
            markdown: block.markdown,
            priority: block.priority
        )
    }

    func controlSidebarClearMetadataBlock(tabArg: String?, key: String) -> ControlSidebarClearMetaBlockResolution {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return .tabNotFound
        }
        if tab.metadataBlocks.removeValue(forKey: key) == nil {
            return .keyNotFound
        }
        return .removed
    }

    func controlSidebarIsValidLogLevel(_ raw: String) -> Bool {
        SidebarLogLevel(rawValue: raw) != nil
    }

    func controlSidebarAppendLog(
        tabArg: String?,
        message: String,
        levelRawValue: String,
        source: String?
    ) -> Bool {
        guard let level = SidebarLogLevel(rawValue: levelRawValue) else {
            // Unreachable: the coordinator validates the level first.
            return true
        }
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if tab.logEntries.count > limit {
            tab.logEntries.removeFirst(tab.logEntries.count - limit)
        }
        return true
    }

    func controlSidebarClearLog(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.logEntries.removeAll()
        return true
    }

    func controlSidebarLogEntries(tabArg: String?) -> [ControlSidebarLogEntrySnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.logEntries.map(Self.controlSidebarLogEntrySnapshot)
    }

    /// Converts one app log entry to its Sendable wire snapshot.
    private static func controlSidebarLogEntrySnapshot(_ entry: SidebarLogEntry) -> ControlSidebarLogEntrySnapshot {
        ControlSidebarLogEntrySnapshot(
            levelRawValue: entry.level.rawValue,
            message: entry.message,
            source: entry.source
        )
    }

    func controlSidebarSetProgress(tabArg: String?, value: Double, label: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.progress = SidebarProgressState(value: value, label: label)
        return true
    }

    func controlSidebarClearProgress(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.progress = nil
        return true
    }
}
