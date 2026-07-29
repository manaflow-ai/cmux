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
        switch self {
        case .workspace(let workspace):
            workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: lifecycle)
        case .dock(let dock):
            guard let panelId else { return }
            dock.setAgentLifecycle(key: key, panelId: panelId, lifecycle: lifecycle)
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
}
