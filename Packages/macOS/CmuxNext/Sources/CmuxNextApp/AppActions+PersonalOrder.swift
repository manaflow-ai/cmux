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
            do { _ = try moveBandWorkspace(workspace, services, origin: invocation.origin) { _ in .step(offset) } } catch { services.registry.refuse(RefusalStrings.describe(error)) }
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

    /// Moves pinned `workspace` (a band item, no list row) where `placement` puts it among its section's items, for every Move
    /// verb (`SidebarLayoutDocument.bandMove`): on the shown sidebar document, else the layout. False when no band lists it.
    static func moveBandWorkspace(_ workspace: WorkspaceModel, _ services: AppServices, origin: ActionOrigin, _ placement: ((String) -> String?) -> SidebarBandPlacement?) throws -> Bool {
        if let moved = services.sidebarDoc.moveBand(workspace: workspace.id, placement) { return moved }
        let refs = WorkspaceLayoutRefs(machines: services.machines), layout = services.sidebarLayout.document, room = services.windows.active?.state.profileID.rawValue
        let item = { (id: String) in refs.ref(forWorkspace: id).flatMap { layout.topItem(for: $0, room: room) } }
        guard let moving = item(workspace.id), let to = placement({ item($0)?.id.rawValue }), let move = layout.bandMove(moving.id.rawValue, to) else { return false }
        try move.layoutOp(moving.id).map { try PinCommands(context: AppActionContext(services: services)).sendLayout($0, title: SidebarDocStore.moveTitle, origin: origin) }; return true
    }
}
