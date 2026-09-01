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

    nonisolated func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?,
        agentMutationGuard: ControlSidebarAgentMutationGuard? = nil
    ) {
        let appFormat = SidebarMetadataFormat(rawValue: format.rawValue) ?? .plain
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            if let agentMutationGuard,
               !owner.acceptsAgentMutationGuard(agentMutationGuard, panelId: panelID) {
                return
            }
            guard Self.shouldReplaceStatusEntry(
                current: owner.statusEntry(key: key, panelId: panelID),
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
                    owner.recordAgentPID(key: key, pid: pid, panelId: panelID)
                }
                return
            }
            owner.setStatusEntry(SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: appFormat,
                timestamp: Date()
            ), key: key, panelId: panelID)
            if let pid {
                owner.recordAgentPID(key: key, pid: pid, panelId: panelID)
            }
        }
    }

    nonisolated func controlSidebarScheduleStatusClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.clearStatusEntry(key: key, panelId: panelID)
            owner.clearAgentPID(key: key, panelId: panelID, clearStatus: false)
        }
    }

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?,
        expectedLifecycleSessionID: String? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            let didReplaceAgentRuntime = owner.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelID,
                expectedLifecycleSessionID: expectedLifecycleSessionID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
            )
            if didReplaceAgentRuntime, let panelID {
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: owner.id,
                    surfaceId: panelID,
                    discardQueuedNotifications: false
                )
            }
        }
    }

    nonisolated func controlSidebarParseAgentLifecycle(_ raw: String) -> String? {
        AgentHibernationLifecycleState.parseCLIValue(raw)?.rawValue
    }

    nonisolated func controlSidebarSetAgentLifecycleUsage() -> String {
        String(
            localized: "socket.sidebar.agentLifecycle.usage",
            defaultValue: "set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>] [--session-id=<id>] [--new-occupant]"
        )
    }

    nonisolated func controlSidebarClearAgentPIDUsage() -> String {
        String(
            localized: "socket.sidebar.clearAgentPID.usage",
            defaultValue: "clear_agent_pid <key> [--tab=<id>] [--panel=<id>] [--clear-status] [--session-id=<id>] [--require-cleared]"
        )
    }

    /// `nonisolated` so the vault-registry disk IO runs on the calling
    /// (socket-worker) thread; only the tab resolution + panel-directory
    /// candidate snapshot crosses to the main actor, as `set_agent_lifecycle`'s
    /// single hop. The legacy body resolved the tab before the registration-id
    /// syntax check; both are side-effect-free reads, so checking the pure
    /// syntax first (to skip the hop for non-registry keys) cannot change the
    /// result.
    nonisolated func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        if AgentHibernationLifecycleStatusKeys.isAllowed(key) {
            return true
        }
        // The manual namespace is reserved for workspace_loading; a custom
        // vault agent must not claim it (hibernation ignores manual keys).
        guard !AgentHibernationLifecycleStatusKeys.isManualKey(key) else {
            return false
        }
        guard CmuxVaultAgentRegistration.isValidID(key) else {
            return false
        }
        let scope: ControlSidebarAgentLifecycleRegistryScope? = v2MainSync {
            guard let owner = self.controlSidebarResolvePanelOwner(
                target: target,
                panelID: panelID
            ) else {
                return nil
            }
            return owner.agentLifecycleRegistryScope(panelId: panelID)
        }
        guard let scope else { return false }
        let registry = scope.loadRegistry()
        return registry.registration(id: key) != nil
    }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?,
        sessionID: String? = nil,
        startsNewOccupant: Bool = false,
        expectedPIDKey: String? = nil,
        expectedPID: Int32? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil
    ) {
        guard let lifecycle = AgentHibernationLifecycleState(rawValue: lifecycleRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.setAgentLifecycle(
                key: key,
                panelId: panelID,
                lifecycle: lifecycle,
                sessionID: sessionID,
                startsNewOccupant: startsNewOccupant,
                expectedPIDKey: expectedPIDKey,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
            )
        }
    }

    nonisolated func controlSidebarApplyAgentLifecycleAndVerifyOwner(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?,
        sessionID: String?,
        startsNewOccupant: Bool,
        expectedPIDKey: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?,
        preflightOnly: Bool,
        clearNotifications: Bool
    ) -> Bool {
        guard let lifecycle = AgentHibernationLifecycleState(rawValue: lifecycleRawValue),
              let panelID else {
            return false
        }
        let guardValue: ControlSidebarAgentMutationGuard
        if let sessionID {
            guardValue = .session(statusKey: key, sessionID: sessionID)
        } else if let pidKey = expectedPIDKey,
                  let pid = expectedPID,
                  let seconds = expectedPIDStartSeconds,
                  let microseconds = expectedPIDStartMicroseconds {
            guardValue = .process(
                statusKey: key,
                pidKey: pidKey,
                pid: pid,
                startSeconds: seconds,
                startMicroseconds: microseconds
            )
        } else {
            return false
        }

        return v2MainSync {
            guard let owner = self.controlSidebarResolvePanelOwner(
                target: target,
                panelID: panelID
            ) else {
                return false
            }
            let accepted = owner.setAgentLifecycle(
                key: key,
                panelId: panelID,
                lifecycle: lifecycle,
                sessionID: sessionID,
                startsNewOccupant: startsNewOccupant,
                expectedPIDKey: expectedPIDKey,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds,
                requireExistingOwner: !startsNewOccupant,
                apply: !preflightOnly
            )
            guard accepted else { return false }
            if preflightOnly { return true }
            guard owner.acceptsAgentMutationGuard(guardValue, panelId: panelID) else {
                return false
            }
            if startsNewOccupant, clearNotifications {
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: owner.id,
                    surfaceId: panelID,
                    discardQueuedNotifications: false
                )
            }
            return true
        }
    }

    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        let before = tab.hasRunningAgentLifecycle(key: key)
        if on {
            // Workspace-scoped: exactly one panel holds a manual key at a time,
            // so reasserting `on` after focus moves never duplicates the loader.
            _ = tab.clearAgentLifecycle(key: key, panelId: nil)
            // Bound distinct manual loaders per workspace so socket clients
            // can't grow lifecycle-key state without limit.
            let manualLoaderCount = tab.agentLifecycleRecordsByPanelId.values.reduce(0) { partial, records in
                partial + records.keys.reduce(0) {
                    AgentHibernationLifecycleStatusKeys.isManualKey($1) ? $0 + 1 : $0
                }
            }
            guard manualLoaderCount < 32 else {
                return ControlSidebarWorkspaceLoadingState(
                    before: before,
                    after: tab.hasRunningAgentLifecycle(key: key),
                    failureReason: "Manual workspace loading limit reached"
                )
            }
            if let panelId = tab.focusedPanelId ?? tab.panels.keys.first {
                tab.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
            } else {
                return ControlSidebarWorkspaceLoadingState(
                    before: before,
                    after: false,
                    failureReason: "Workspace has no panel for manual loading"
                )
            }
        } else {
            // Workspace-scoped: clear from all panels, not just the caller's.
            _ = tab.clearAgentLifecycle(key: key, panelId: nil)
        }
        return ControlSidebarWorkspaceLoadingState(before: before, after: tab.hasRunningAgentLifecycle(key: key))
    }

    /// `nonisolated` with the settings write inside `agent_hibernation`'s
    /// single main hop: `setValues` posts the settings-did-change notification
    /// synchronously, and its observers assume the main thread (the legacy
    /// body always ran there). Keeping the hop synchronous also preserves the
    /// apply-then-reply ordering main-thread test callers rely on.
    nonisolated func controlSidebarSetAgentHibernation(enabled: Bool) {
        v2MainSync {
            AgentHibernationSettings.setValues(enabled: enabled)
        }
    }

    nonisolated func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        expectedLifecycleSessionID: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?,
        requireOwnedKey: Bool = false
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: clearStatus,
                expectedLifecycleSessionID: expectedLifecycleSessionID,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds,
                requireOwnedKey: requireOwnedKey
            )
        }
    }

    nonisolated func controlSidebarClearAgentPIDAndVerifyOwner(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        expectedLifecycleSessionID: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?,
        requireOwnedKey: Bool
    ) -> Bool {
        v2MainSync {
            guard let owner = self.controlSidebarResolvePanelOwner(
                target: target,
                panelID: panelID
            ) else {
                return false
            }
            return owner.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: clearStatus,
                expectedLifecycleSessionID: expectedLifecycleSessionID,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds,
                requireOwnedKey: requireOwnedKey
            )
        }
    }

    nonisolated func controlSidebarScheduleMetadataBlockUpsert(
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

    nonisolated func controlSidebarIsValidLogLevel(_ raw: String) -> Bool {
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
