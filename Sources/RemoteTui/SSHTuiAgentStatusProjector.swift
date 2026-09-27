import CmuxSidebar
import CmuxSurfaceCatalogModel
import Foundation

/// Mirrors agent rows of `cmux ssh` terminals into the sidebar, the way local
/// agent hooks drive it: a Running / Needs input / Idle status per agent kind
/// and a per-panel lifecycle for the activity spinner and task status.
///
/// The cmux-tui daemon on the host folds the provider hooks into its agent
/// roster (hook > plugin > detected); the catalog carries each row as the
/// terminal's `agent` badge. Completion and approval notifications already
/// arrive through the daemon's notification ledger, and the tab icon through
/// `syncCloudTerminalTabIcons`, so this covers only the sidebar status.
@MainActor
final class SSHTuiAgentStatusProjector {
    private let catalog: SurfaceCatalog
    private let workspaceLookup: @MainActor (UUID) -> Workspace?
    private var observer: NSObjectProtocol?
    /// Lifecycle slots this projector set, per workspace and panel.
    private var appliedLifecycles: [UUID: [UUID: String]] = [:]
    /// Workspaces holding a status entry this projector wrote.
    private var workspacesWithStatus: Set<UUID> = []

    init(catalog: SurfaceCatalog, workspaceLookup: @escaping @MainActor (UUID) -> Workspace? = SSHTuiAgentStatusProjector.workspace(id:)) {
        self.catalog = catalog
        self.workspaceLookup = workspaceLookup
        observer = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification, object: catalog, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    func reconcile() {
        var desired: [UUID: [UUID: RemoteAgentSidebarStatus]] = [:]
        for projection in catalog.projections where projection.resource.machine.isSSH && projection.resource.kind == .terminal {
            // A dropped link keeps the last reported rows; show nothing rather than a stale Running.
            guard catalog.machines[projection.resource.machine]?.linkState == .connected,
                  let resource = catalog.resources[projection.resource], resource.lifecycle != .exited,
                  let badge = resource.agent, let status = RemoteAgentSidebarStatus(badge: badge) else { continue }
            desired[projection.workspaceID, default: [:]][projection.panelID] = status
        }
        var nextLifecycles: [UUID: [UUID: String]] = [:]
        var nextWorkspacesWithStatus: Set<UUID> = []
        for workspaceID in workspacesWithStatus.union(appliedLifecycles.keys).union(desired.keys) {
            guard let workspace = workspaceLookup(workspaceID) else {
                // Not reachable right now (moving between windows): keep what we
                // own so a later pass can still clear it.
                if let owned = appliedLifecycles[workspaceID] { nextLifecycles[workspaceID] = owned }
                if workspacesWithStatus.contains(workspaceID) { nextWorkspacesWithStatus.insert(workspaceID) }
                continue
            }
            let panels = desired[workspaceID] ?? [:]
            let lifecycles = applyLifecycles(panels, previous: appliedLifecycles[workspaceID] ?? [:], to: workspace)
            applyStatusEntries(RemoteAgentSidebarStatus.workspaceSlots(panels.values), to: workspace)
            if !lifecycles.isEmpty { nextLifecycles[workspaceID] = lifecycles }
            if !panels.isEmpty { nextWorkspacesWithStatus.insert(workspaceID) }
        }
        appliedLifecycles = nextLifecycles
        workspacesWithStatus = nextWorkspacesWithStatus
    }

    /// Returns the lifecycle slot now set per panel.
    private func applyLifecycles(
        _ panels: [UUID: RemoteAgentSidebarStatus], previous: [UUID: String], to workspace: Workspace
    ) -> [UUID: String] {
        var applied: [UUID: String] = [:]
        for (panelID, status) in panels {
            guard let lifecycle = Self.lifecycle(for: status.activity) else { continue }
            if workspace.agentLifecycleStatesByPanelId[panelID]?[status.statusKey] != lifecycle {
                workspace.setAgentLifecycle(key: status.statusKey, panelId: panelID, lifecycle: lifecycle)
            }
            applied[panelID] = status.statusKey
        }
        for (panelID, key) in previous where applied[panelID] != key {
            workspace.clearAgentLifecycle(key: key, panelId: panelID)
        }
        return applied
    }

    private func applyStatusEntries(_ slots: [String: RemoteAgentSidebarStatus.Activity], to workspace: Workspace) {
        for key in workspace.statusEntries.keys where RemoteAgentSidebarStatus.isOwnedStatusKey(key) && slots[key] == nil {
            workspace.statusEntries.removeValue(forKey: key)
        }
        for (key, activity) in slots {
            let entry = Self.statusEntry(key: key, activity: activity)
            if let current = workspace.statusEntries[key], current.value == entry.value, current.icon == entry.icon,
               current.color == entry.color, current.priority == entry.priority { continue }
            workspace.statusEntries[key] = entry
        }
    }

    /// Idle stays out of the lifecycle map: an idle lifecycle marks a panel
    /// eligible for agent hibernation, which only applies to local agents.
    static func lifecycle(for activity: RemoteAgentSidebarStatus.Activity) -> AgentHibernationLifecycleState? {
        switch activity {
        case .running: .running
        case .needsInput: .needsInput
        case .idle: nil
        }
    }

    /// The same text, symbol, and color the local agent hooks write.
    static func statusEntry(key: String, activity: RemoteAgentSidebarStatus.Activity) -> SidebarStatusEntry {
        switch activity {
        case .running:
            SidebarStatusEntry(key: key, value: String(localized: "agent.generic.status.running", defaultValue: "Running"),
                               icon: "bolt.fill", color: "#4C8DFF", timestamp: Date())
        case .needsInput:
            SidebarStatusEntry(key: key, value: String(localized: "feed.status.needsInput", defaultValue: "Needs input"),
                               icon: "bell.fill", color: "#4C8DFF", priority: 100, timestamp: Date())
        case .idle:
            SidebarStatusEntry(key: key, value: String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle"),
                               icon: "pause.circle.fill", color: "#8E8E93", timestamp: Date())
        }
    }

    static func workspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }
}
