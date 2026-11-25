import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

extension AppActions {
    /// Move Workspace Up/Down in personal mode: one slot among the rows of
    /// the active window's sidebar, as a personal order change in the home
    /// session (the workspace's own daemon order is not touched).
    static func movePersonalWorkspace(_ services: AppServices, _ invocation: ActionInvocation, by offset: Int) {
        guard let workspace = scope(services, invocation).workspace, let sidebar = services.windows.active?.sidebar else { return }
        let machines = services.machines, doc = services.sidebarDoc
        let visible = sidebar.model.selectableWorkspaces.map(\.id)
        guard let position = visible.firstIndex(of: SidebarWorkspaceID(workspace.id)) else {
            // A pinned workspace has no list row: it moves one place among the items of its section (Pinned).
            if let store = doc.activeStore, let item = doc.item(workspace: workspace.id),
               let to = store.shown?.layout.stepMoveTarget(item, by: offset) {
                store.move([item], to: to, title: SidebarDocStore.moveTitle)
            } else if let ref = WorkspaceLayoutRefs(machines: machines).ref(forWorkspace: workspace.id),
                      let item = services.sidebarLayout.document.topItem(for: ref, room: services.windows.active?.state.profileID.rawValue),
                      let op = services.sidebarLayout.document.stepMoveOp(item.id, by: offset) {
                let commands = PinCommands(context: AppActionContext(services: services))
                do { try commands.sendLayout(op, title: SidebarDocStore.moveTitle, origin: invocation.origin) } catch {
                    services.registry.refuse(RefusalStrings.describe(error))
                }
            }
            return
        }
        guard visible.indices.contains(position + offset) else { return }
        let target = visible[position + offset]
        sidebar.model.noteUserMove() // the structural set that shows this move may reveal the moved row
        // The sidebar document: one move next to the row the person sees above or below (no personal order).
        if let store = doc.activeStore, let item = doc.item(workspace: workspace.id),
           let anchor = doc.item(workspace: target.rawValue), let section = store.records.items[anchor]?.section {
            let parent = store.records.items[anchor]?.parent
            let to = offset > 0 ? SidebarDocTarget(section: section, parent: parent, after: anchor) : SidebarDocTarget(section: section, parent: parent, before: anchor)
            return store.move([item], to: to, title: SidebarDocStore.moveTitle)
        }
        guard let moved = WindowProfiles.qualified(workspace.id, machines: machines),
              let anchor = WindowProfiles.qualified(target.rawValue, machines: machines) else { return }
        let order = PersonalSidebar.globalOrder(machines.local.store.personal).filter { $0 != "\(moved.session)/\(moved.key)" }
        guard let anchorIndex = order.firstIndex(of: "\(anchor.session)/\(anchor.key)") else { return }
        let index = offset > 0 ? anchorIndex + 1 : anchorIndex
        let key = WorkspaceKey(rawValue: moved.key)
        let resource = machines.local.store.personalStateID(session: moved.session, key: key)
        machines.local.send("set-personal-workspace") {
            try await $0.state.placePersonalWorkspace(session: moved.session, key: key, resource: resource, index: index)
        }
    }
}
