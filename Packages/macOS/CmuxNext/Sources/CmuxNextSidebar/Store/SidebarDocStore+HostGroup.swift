import Foundation

/// Remote groups on the sidebar document (remote-groups-DESIGN.md slice 4).
extension SidebarDocStore {
    /// Marks the machine section of daemon session `session` a remote group (``SidebarDocHostGroupPlan``)
    /// in one change with no undo step of its own; nothing when it already is one.
    /// - Parameters:
    ///   - session: the host daemon's session id (its `registryID`).
    ///   - title: the change's name (the undo menu and the refusal HUD).
    public func markHostGroup(session: String, title: String) {
        guard !pendingHostGroupMarks.contains(session) else { return }
        let ops = SidebarDocHostGroupPlan(session: session, records: records).ops
        guard !ops.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ops) else {
            pendingHostGroupMarks.remove(session)
            return
        }
        pendingHostGroupMarks.insert(session)
        let intent = SidebarMirrorIntent.apply(data, key: SidebarDocStore.newKey())
        do {
            try submit(intent, title: title, undoable: false, outcome: { [weak self] _ in
                self?.pendingHostGroupMarks.remove(session)
            }) { remote, key, stamped in
                try await remote.apply(ops: stamped ?? data, key: key)
            }
        } catch {
            pendingHostGroupMarks.remove(session)
            onRefused(error.message)
        }
    }
}
