import Foundation

/// Remote groups on the sidebar document (remote-groups-DESIGN.md slice 4).
extension SidebarDocStore {
    /// Marks the machine section of daemon session `session` a remote group (``SidebarDocHostGroupPlan``)
    /// in one change with no undo step of its own; nothing when it already is one.
    /// - Parameters:
    ///   - session: the host daemon's session id (its `registryID`).
    ///   - title: the change's name (the undo menu and the refusal HUD).
    public func markHostGroup(session: String, title: String) {
        let ops = SidebarDocHostGroupPlan(session: session, records: records).ops
        guard !ops.isEmpty else { return }
        send(ops: ops, title: title, undoable: false)
    }
}
