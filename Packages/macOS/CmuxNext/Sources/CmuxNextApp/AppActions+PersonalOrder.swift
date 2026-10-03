import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

extension AppActions {
    /// Move Workspace Up/Down in personal mode: one slot among the rows of
    /// the active window's sidebar, as a personal order change in the home
    /// session (the workspace's own daemon order is not touched).
    static func movePersonalWorkspace(_ services: AppServices, _ invocation: ActionInvocation, by offset: Int) {
        guard let workspace = scope(services, invocation).workspace, let sidebar = services.windows.active?.sidebar else { return }
        let visible = sidebar.model.selectableWorkspaces.map(\.id)
        guard let position = visible.firstIndex(of: SidebarWorkspaceID(workspace.id)), visible.indices.contains(position + offset) else { return }
        let target = visible[position + offset]
        let machines = services.machines
        guard let moved = WindowProfiles.qualified(workspace.id, machines: machines),
              let anchor = WindowProfiles.qualified(target.rawValue, machines: machines) else { return }
        let order = PersonalSidebar.globalOrder(machines.local.store.personal).filter { $0 != "\(moved.session)/\(moved.key)" }
        guard let anchorIndex = order.firstIndex(of: "\(anchor.session)/\(anchor.key)") else { return }
        let index = offset > 0 ? anchorIndex + 1 : anchorIndex
        machines.local.send("set-personal-workspace") {
            try await $0.setPersonalWorkspace(SetPersonalWorkspaceRequest(sessionID: moved.session, workspaceKey: WorkspaceKey(rawValue: moved.key),
                                                                          index: index))
        }
    }
}
