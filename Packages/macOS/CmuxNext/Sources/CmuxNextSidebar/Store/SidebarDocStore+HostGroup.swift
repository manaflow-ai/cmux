import Foundation

/// Remote groups on the sidebar document (remote-groups-DESIGN.md slice 4).
extension SidebarDocStore {
    func clearPendingHostGroupMark(session: String, key: String) {
        guard pendingHostGroupMarks[session] == key else { return }
        pendingHostGroupMarks.removeValue(forKey: session)
    }

    /// Marks the machine section of daemon session `session` a remote group (``SidebarDocHostGroupPlan``)
    /// in one change with no undo step of its own; nothing when it already is one.
    /// - Parameters:
    ///   - session: the host daemon's session id (its `registryID`).
    ///   - title: the change's name (the undo menu and the refusal HUD).
    public func markHostGroup(session: String, title: String) {
        guard pendingHostGroupMarks[session] == nil else { return }
        let ops = SidebarDocHostGroupPlan(session: session, records: records).ops
        guard !ops.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ops) else {
            pendingHostGroupMarks.removeValue(forKey: session)
            return
        }
        let intent = SidebarMirrorIntent.apply(data, key: SidebarDocStore.newKey())
        pendingHostGroupMarks[session] = intent.idempotencyKey
        do {
            try submit(intent, title: title, undoable: false, outcome: { [weak self] _ in
                self?.clearPendingHostGroupMark(session: session, key: intent.idempotencyKey)
            }) { remote, key, stamped in
                try await remote.apply(ops: stamped ?? data, key: key)
            }
        } catch {
            clearPendingHostGroupMark(session: session, key: intent.idempotencyKey)
            onRefused(error.message)
        }
    }
}
