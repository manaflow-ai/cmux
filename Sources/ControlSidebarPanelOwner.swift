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

    func statusEntry(key: String, panelId: UUID?) -> SidebarStatusEntry? {
        switch self {
        case .workspace(let workspace): workspace.statusEntries[key]
        case .dock(let dock):
            panelId.flatMap { dock.agentRuntimeStatusEntry(key: key, panelId: $0) }
        }
    }

    func setStatusEntry(_ entry: SidebarStatusEntry, key: String, panelId: UUID?) {
        switch self {
        case .workspace(let workspace): workspace.statusEntries[key] = entry
        case .dock(let dock):
            guard let panelId else { return }
            dock.setAgentRuntimeStatusEntry(entry, key: key, panelId: panelId)
        }
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
    func recordAgentPID(key: String, pid: pid_t, panelId: UUID?) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.recordAgentPID(key: key, pid: pid, panelId: panelId)
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.recordAgentPID(key: key, pid: pid, panelId: panelId)
        }
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState
    ) {
        let didResumeFromAnotherLifecycle: Bool
        switch self {
        case .workspace(let workspace):
            guard let targetPanelId = panelId ?? workspace.focusedPanelId,
                  workspace.panels[targetPanelId] != nil else {
                return
            }
            let previousLifecycle = workspace.agentLifecycleStatesByPanelId[targetPanelId]?[key]
            workspace.setAgentLifecycle(key: key, panelId: targetPanelId, lifecycle: lifecycle)
            didResumeFromAnotherLifecycle = lifecycle == .running &&
                previousLifecycle != .running
        case .dock(let dock):
            guard let panelId, dock.panels[panelId] != nil else { return }
            let previousLifecycle = dock.agentRuntimeByPanelId[panelId]?.agentLifecycleStates[key]
            dock.setAgentLifecycle(key: key, panelId: panelId, lifecycle: lifecycle)
            didResumeFromAnotherLifecycle = lifecycle == .running &&
                previousLifecycle != .running
        }
        guard didResumeFromAnotherLifecycle,
              !AgentHibernationLifecycleStatusKeys.isManualKey(key) else {
            return
        }
        // A lifecycle transition is activity even when the provider did not
        // send terminal input. Retire only the live sidebar previews; the
        // notification feed remains the historical record.
        let notificationStore: TerminalNotificationStore?
        switch self {
        case .workspace:
            notificationStore = AppDelegate.shared?.notificationStore
        case .dock(let dock):
            notificationStore = dock.resolvedNotificationStore()
        }
        notificationStore?.clearSidebarNotificationPreviews(forTabId: id)
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
        requireOwnedKey: Bool = false
    ) {
        switch self {
        case .workspace(let workspace):
            workspace.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey
            )
        case .dock(let dock):
            guard let panelId else { return }
            dock.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey
            )
        }
    }

    private static func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
