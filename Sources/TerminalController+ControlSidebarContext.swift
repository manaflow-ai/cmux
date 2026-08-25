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
        processGeneration: ControlSidebarAgentProcessGeneration? = nil
    ) {
        let appFormat = SidebarMetadataFormat(rawValue: format.rawValue) ?? .plain
        let exactProcessIdentity = processGeneration.map {
            AgentPIDProcessIdentity(
                pid: $0.pid,
                startSeconds: $0.startSeconds,
                startMicroseconds: $0.startMicroseconds
            )
        }
        let reconstructedProcessIdentity = pid.flatMap {
            AgentPIDProcessIdentity(pid: $0)
        }
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            if let pid {
                let keyIsBuiltIn = AgentHibernationLifecycleStatusKeys(
                    rawValue: key
                ).isBuiltInNamespace
                let acceptedProcessIdentity: AgentPIDProcessIdentity?
                if keyIsBuiltIn {
                    if owner.usesRemoteAgentProcessNamespace(panelId: panelID) {
                        // Relay PIDs belong to the remote host. Preserve the
                        // status update without binding that numeric PID to
                        // this Mac's process table.
                        acceptedProcessIdentity = nil
                    } else {
                        guard let exactProcessIdentity,
                              exactProcessIdentity.pid == pid else {
                            return
                        }
                        acceptedProcessIdentity = exactProcessIdentity
                    }
                } else {
                    acceptedProcessIdentity =
                        exactProcessIdentity ?? reconstructedProcessIdentity
                }
                guard owner.recordAgentPID(
                    key: key,
                    pid: pid,
                    panelId: panelID,
                    acceptedProcessIdentity: acceptedProcessIdentity
                ).accepted else {
                    return
                }
            } else if AgentHibernationLifecycleStatusKeys(
                rawValue: key
            ).isAllowed,
                      !owner.usesRemoteAgentProcessNamespace(
                          panelId: panelID
                      ),
                      !owner.hasLiveAgentProcess(
                          statusKey: key,
                          panelId: panelID
                      ) {
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
        }
    }

    nonisolated func controlSidebarScheduleStatusClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.clearStatusEntry(key: key, panelId: panelID)
            _ = owner.clearAgentLifecycle(key: key, panelId: panelID)
            owner.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: false,
                requireOwnedKey: true
            )
        }
    }

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    ) {
        let exactProcessIdentity = processGeneration.map {
            AgentPIDProcessIdentity(
                pid: $0.pid,
                startSeconds: $0.startSeconds,
                startMicroseconds: $0.startMicroseconds
            )
        }
        let reconstructedProcessIdentity = AgentPIDProcessIdentity(pid: pid)
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            // The coordinator rejects missing generations for built-ins. Keep
            // the same invariant at the mutation boundary so a queued command
            // cannot reconstruct ownership from a recycled numeric PID.
            let acceptedProcessIdentity: AgentPIDProcessIdentity?
            if let exactProcessIdentity {
                acceptedProcessIdentity = exactProcessIdentity
            } else if AgentHibernationLifecycleStatusKeys(
                rawValue: key
            ).isBuiltInNamespace {
                if owner.usesRemoteAgentProcessNamespace(panelId: panelID) {
                    acceptedProcessIdentity = nil
                } else {
                    return
                }
            } else {
                acceptedProcessIdentity = reconstructedProcessIdentity
            }
            let result = owner.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelID,
                acceptedProcessIdentity: acceptedProcessIdentity
            )
            if result.replacedOtherRuntime, let panelID {
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: owner.id,
                    surfaceId: panelID,
                    discardQueuedNotifications: false
                )
            }
        }
    }

    nonisolated func controlSidebarParseAgentLifecycle(_ raw: String) -> String? {
        AgentHibernationLifecycleState(cliValue: raw)?.rawValue
    }

    nonisolated func controlSidebarAgentStrings() -> ControlSidebarAgentStrings {
        ControlSidebarAgentStrings(
            usageErrorFormat: String(
                localized: "socket.sidebar.agent.usageError",
                defaultValue: "ERROR: Usage: %@"
            ),
            setAgentPIDUsage: String(
                localized: "socket.sidebar.agent.setPIDUsage",
                defaultValue: "set_agent_pid <key> <pid> [--tab=<id>] [--panel=<id>] [--pid=<pid> --pid-start-seconds=<seconds> --pid-start-microseconds=<microseconds>]"
            ),
            setAgentLifecycleUsage: String(
                localized: "socket.sidebar.agent.setLifecycleUsage",
                defaultValue: "set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>] [--pid=<pid> --pid-start-seconds=<seconds> --pid-start-microseconds=<microseconds>]"
            ),
            processGenerationPIDMismatch: String(
                localized:
                    "socket.sidebar.agent.processGenerationPIDMismatch",
                defaultValue:
                    "ERROR: Agent process generation PID does not match <pid>"
            ),
            invalidLifecycleFormat: String(
                localized: "socket.sidebar.agent.invalidLifecycle",
                defaultValue:
                    "ERROR: Invalid agent lifecycle '%1$@' — usage: %2$@"
            ),
            unsupportedLifecycleKeyFormat: String(
                localized: "socket.sidebar.agent.unsupportedLifecycleKey",
                defaultValue:
                    "ERROR: Unsupported agent lifecycle key '%@'"
            ),
            processGenerationRequired: String(
                localized: "socket.sidebar.agent.processGenerationRequired",
                defaultValue:
                    "ERROR: Agent process generation is required for this agent."
            ),
            invalidProcessGenerationFormat: String(
                localized: "socket.sidebar.agent.invalidProcessGeneration",
                defaultValue:
                    "ERROR: Invalid agent process generation — usage: %@"
            )
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
        if AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed {
            return true
        }
        // The manual namespace is reserved for workspace_loading; a custom
        // vault agent must not claim it (hibernation ignores manual keys).
        guard !AgentHibernationLifecycleStatusKeys(rawValue: key).isManual else {
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

    nonisolated func controlSidebarRequiresAgentProcessGeneration(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        // Never reconstruct a missing generation from the current numeric PID:
        // local and relayed hooks can both arrive after that PID was recycled
        // in their respective process namespaces.
        guard AgentHibernationLifecycleStatusKeys(
            rawValue: key
        ).isBuiltInNamespace else {
            return false
        }
        // A relay's PID is meaningful only on the remote host; the owner
        // accepts it without local generation binding once the target is
        // resolved on the main actor. Unresolved owners stay fail-closed.
        return v2MainSync {
            guard let owner = self.controlSidebarResolvePanelOwner(
                target: target,
                panelID: panelID
            ) else {
                return true
            }
            return !owner.usesRemoteAgentProcessNamespace(panelId: panelID)
        }
    }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    ) {
        guard let lifecycle = AgentHibernationLifecycleState(rawValue: lifecycleRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        let exactProcessGeneration = processGeneration.map {
            AgentPIDProcessIdentity(
                pid: $0.pid,
                startSeconds: $0.startSeconds,
                startMicroseconds: $0.startMicroseconds
            )
        }
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            if AgentHibernationLifecycleStatusKeys(rawValue: key).isAllowed {
                // The parser rejects missing generations for built-ins; keep
                // this mutation-boundary guard for queued replacement races.
                if owner.usesRemoteAgentProcessNamespace(panelId: panelID) {
                    // Remote PIDs are authoritative only in the relay's
                    // namespace; do not require a local start-time tuple.
                } else {
                    guard let exactProcessGeneration else {
                        return
                    }
                    guard
                      owner.hasLiveAgentProcess(
                          statusKey: key,
                          panelId: panelID,
                          matching: exactProcessGeneration
                      ) else {
                        return
                    }
                }
            }
            owner.setAgentLifecycle(
                key: key,
                panelId: panelID,
                lifecycle: lifecycle,
                processGeneration: exactProcessGeneration
            )
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
            let manualLoaderCount = tab.agentLifecycleStatesByPanelId.values.reduce(0) { partial, states in
                partial + states.keys.reduce(0) {
                    AgentHibernationLifecycleStatusKeys(rawValue: $1).isManual
                        ? $0 + 1
                        : $0
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
        requireOwnedKey: Bool = false
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: clearStatus,
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
