import CmuxNextBridge
import CmuxNextSidebar

// The sidebar side of window membership: positions in this window's
// (filtered) sidebar map to the daemon's global order, and workspaces
// dragged in from another window land here.
extension SidebarBridge {
    /// Daemon root index for `position` in this window's sidebar `sections`
    /// (which list only this window's workspaces), excluding `ids`.
    func daemonRootIndex(for position: DropPosition, moving ids: [SidebarWorkspaceID], in sections: [SidebarRowSection]) -> Int? {
        guard case .machine(let machine) = position.section, let daemon = services.machines.daemon(machine: machine.rawValue) else {
            return nil
        }
        let scoped = sections.filter { $0.id == position.section }
        guard let local = WorkspaceOrdering.rootIndex(for: position, moving: ids, in: scoped) else { return nil }
        let moved = Set(ids.map(\.rawValue))
        let localOrder = scoped.flatMap(\.workspaces).map(\.id.rawValue).filter { !moved.contains($0) }
        let global = WindowManager.orderedIDs(of: daemon, machines: services.machines).filter { !moved.contains($0) }
        return SidebarMembership.globalIndex(localIndex: local, local: localOrder, global: global)
    }

    /// Workspaces dragged in from another window (or moved by an action):
    /// this window takes them and selects the first; with a `position`, one
    /// daemon order command each puts them there.
    func accept(_ ids: [SidebarWorkspaceID], at position: DropPosition?) {
        guard let state else { return }
        let before = model.sections
        guard services.windows.moveWorkspaces(ids.map(\.rawValue), toWindow: state.id) else { return }
        if let position { place(ids, at: position, in: before) }
    }

    /// Puts `ids` at `position` of this window's `sections` (taken before
    /// the move): personal order in the home session when it serves
    /// personal state, else reorder commands to the owning daemon.
    func place(_ ids: [SidebarWorkspaceID], at position: DropPosition, in sections: [SidebarRowSection]) {
        if usesPersonalOrganization {
            placePersonal(ids, at: position, in: sections)
        } else {
            reorder(ids, to: position, in: sections)
        }
    }

    /// Workspaces dragged from another window onto a group header here.
    func accept(_ ids: [SidebarWorkspaceID], intoGroup group: GroupID) {
        guard let state else { return }
        guard services.windows.moveWorkspaces(ids.map(\.rawValue), toWindow: state.id) else { return }
        handle(.move(ids, toGroup: group))
    }

    /// Ids of this window's workspaces, in sidebar order.
    var memberIDs: [SidebarWorkspaceID] {
        guard let state else { return [] }
        return services.windows.registry.members(of: state.id).map(SidebarWorkspaceID.init)
    }
}
