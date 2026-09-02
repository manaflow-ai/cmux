import CmuxSidebar
import Darwin
import Foundation

/// The current owner of panel-scoped sidebar and agent runtime mutations.
@MainActor
enum ControlSidebarPanelOwner {
    case workspace(Workspace)
    case dock(DockSplitStore)

    var id: UUID {
        switch self {
        case .workspace(let workspace): workspace.id
        case .dock(let dock): dock.workspaceId
        }
    }

    func agentLifecycleRegistryScope(panelId: UUID?) -> ControlSidebarAgentLifecycleRegistryScope {
        switch self {
        case .workspace(let workspace):
            let candidates = [
                panelId.flatMap { workspace.effectivePanelDirectory(panelId: $0) },
                workspace.focusedPanelId.flatMap { workspace.effectivePanelDirectory(panelId: $0) },
                workspace.usesRemoteDirectoryProvenance
                    ? workspace.presentedCurrentDirectory
                    : workspace.currentDirectory,
            ]
            return .project(candidates.compactMap(Self.normalizedOptionValue).first)
        case .dock(let dock):
            guard let panelId else { return .project(nil) }
            return dock.agentLifecycleRegistryScope(for: panelId)
        }
    }

    @discardableResult
    func upsertStatusEntry(
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat,
        panelId: UUID?,
        pid: pid_t?,
        agentEventTime: TimeInterval?,
        enforceAgentEventOrdering: Bool = true
    ) -> SidebarStatusEntryReplacementDecision {
        switch self {
        case .workspace(let workspace):
            return workspace.upsertSidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: format,
                panelId: panelId,
                pid: pid,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        case .dock(let dock):
            guard let panelId else { return .stale }
            return dock.upsertAgentRuntimeStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: format,
                panelId: panelId,
                pid: pid,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        }
    }

    /// Compatibility bridge for feed attention producers that already own a
    /// fully formed sidebar row. Keep the mutation on this owner so workspace
    /// and Dock paths share the same replacement/ordering policy.
    @discardableResult
    func setStatusEntry(
        _ entry: SidebarStatusEntry,
        key: String,
        panelId: UUID?
    ) -> SidebarStatusEntryReplacementDecision {
        // Feed attention is an app-owned overlay, not a detached hook event.
        // Keep the existing hook timestamp on the row, but never advance the
        // hook watermark from this compatibility path.
        return upsertStatusEntry(
            key: key,
            value: entry.value,
            icon: entry.icon,
            color: entry.color,
            url: entry.url,
            priority: entry.priority,
            format: entry.format,
            panelId: panelId,
            pid: nil,
            agentEventTime: nil,
            enforceAgentEventOrdering: false
        )
    }

    func clearStatusEntry(key: String, panelId: UUID?) {
        switch self {
        case .workspace(let workspace):
            workspace.statusEntries.removeValue(forKey: key)
        case .dock(let dock):
            guard let panelId else { return }
            dock.clearAgentRuntimeStatusEntry(key: key, panelId: panelId)
        }
    }

    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelId,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelId,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        }
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) {
        switch self {
        case .workspace(let workspace):
            workspace.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        case .dock(let dock):
            guard let panelId else { return }
            dock.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        }
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID?) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.clearAgentLifecycle(key: key, panelId: panelId)
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.clearAgentLifecycle(key: key, panelId: panelId)
        }
    }

    func clearAgentPID(
        key: String,
        panelId: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool = false,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false
    ) {
        switch self {
        case .workspace(let workspace):
            workspace.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        case .dock(let dock):
            guard let panelId else { return }
            dock.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey,
                agentEventTime: agentEventTime,
                enforceAgentEventOrdering: enforceAgentEventOrdering
            )
        }
    }

    @discardableResult
    func acceptAgentRuntimeMutation(
        statusKey: String,
        panelId: UUID?,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool,
        isLifecycleMutation: Bool = false
    ) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.acceptAgentRuntimeMutation(
                statusKey: statusKey,
                panelId: panelId,
                agentEventTime: agentEventTime,
                enforceOrdering: enforceOrdering,
                isLifecycleMutation: isLifecycleMutation
            )
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.acceptAgentRuntimeMutation(
                statusKey: statusKey,
                panelId: panelId,
                agentEventTime: agentEventTime,
                enforceOrdering: enforceOrdering,
                isLifecycleMutation: isLifecycleMutation
            )
        }
    }

    private static func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
