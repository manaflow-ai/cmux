import Foundation

extension SidebarDocStore {
    /// Sends a move intent as one document move (sidebar-v2 S4): a list
    /// reorder or group move (`DropPosition`, counted without the moved
    /// items, becomes an anchor next to a sibling the person saw), a band
    /// drop or reorder, Pin and Unpin (the old "pin group" is plain Pin: the
    /// group moves into Pinned). A group's collapse is client view state.
    /// False: not a move (the older path handles it). `undoable` false (a new workspace placed
    /// at its slot) puts no undo step and leaves to the older path a placement whose workspace
    /// or anchor the document cannot name yet.
    public func handle(_ intent: SidebarIntent, model: SidebarModel, drag: SidebarDocDrag, pinTitle: String, unpinTitle: String,
                       undoable: Bool = true) -> Bool {
        let title = Self.moveTitle
        // A workspace the document does not place yet moves with its adopt in the same `sidebar.apply`.
        var adopt: [[String: Any]] = []
        func items(_ ids: [WorkspaceID]) -> [String] {
            ids.compactMap { id in
                if let item = drag.item(.workspace(id)) { return item }
                guard let ref = drag.adoptRef(id) else { return nil }
                adopt.append(["op": "adopt", "refs": [ref]])
                return Self.adoptedID(SidebarDocWorkspaceRef(sessionID: ref["session_id"] as? String ?? "", workspaceID: ref["workspace_id"] as? String ?? ""))
            }
        }
        func move(_ moving: [String], to target: SidebarDocTarget, title: String) {
            // main-actor-ok: one SidebarDocTarget (section, parent, before, after, index), fixed size.
            guard !adopt.isEmpty || !undoable, let to = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) else {
                return self.move(moving, to: target, title: title)
            }
            send(ops: adopt + [["op": "move", "items": moving, "to": to]], title: title, undoable: undoable)
        }
        if let (ops, undoable) = groupOps(intent, items: items) {
            send(ops: adopt + ops, title: Self.moveTitle, undoable: undoable)
            return true
        }
        func layoutMove(_ moving: [String], _ section: LayoutSectionID, _ index: Int) {
            move(moving, to: SidebarDocDrag.target(section, index: index, moving: moving, layout: model.layout), title: title)
        }
        func setPinned(_ moving: [String], _ pinned: Bool) {
            if !adopt.isEmpty { return send(ops: adopt + [["op": pinned ? "pin" : "unpin", "items": moving]], title: pinned ? pinTitle : unpinTitle) }
            if pinned { pin(moving, title: pinTitle) } else { unpin(moving, title: unpinTitle) }
        }
        switch intent {
        case .reorder(let ids, let position):
            let moving = items(ids)
            if !undoable, moving.count != ids.count { return false }
            // Rows the document does not place, on a machine it holds no section for here: their adopt (already
            // queued by `items`) makes the section, then they move to the slot (a219's gap, pinning-DESIGN.md).
            guard let anchored = drag.anchoredTarget(position, moving: moving, model: model)
                ?? drag.unplacedTarget(position, moving: ids).map({ (target: $0, adopt: [[String: String]]()) }) else { return false }
            // A placement (a new workspace at its slot) next to a row the document shows no item for yet is left to the
            // older path: the daemon may hold that row's item where this client does not see it, and refuses the move
            // (`invalid_target`), which left each workspace a classic import made at the top, in reverse order.
            if !undoable, !anchored.adopt.isEmpty { return false }
            // An anchor this client has no item for is adopted in the same `sidebar.apply`, before the move.
            adopt += anchored.adopt.map { ref -> [String: Any] in ["op": "adopt", "refs": [ref]] }
            move(moving, to: anchored.target, title: title)
        case .reorderGroup(let group, let index):
            guard let section = model.sections.first(where: { $0.nodes.contains { $0.id == .group(group) } }),
                  let anchored = drag.anchoredTarget(DropPosition(section: section.id, index: index), moving: [item(group: group)], model: model)
            else { return false }
            adopt += anchored.adopt.map { ref -> [String: Any] in ["op": "adopt", "refs": [ref]] }
            move([item(group: group)], to: anchored.target, title: title)
        case .move(let ids, let group):
            // The displayed group's indexed section includes pending adopts and placements. Its provisional record
            // may have no section yet, or predate a pending pin; the reducer's displayed placement wins (#26382).
            let parent = item(group: group)
            guard let section = model.groupSection(group).flatMap({ drag.section($0.id) })
                ?? shownRecords.items[parent]?.section else { return false }
            move(items(ids), to: SidebarDocTarget(section: section, parent: parent), title: title)
        case .setPinned(let ids, let pinned):
            setPinned(items(ids), pinned)
        case .setGroupPinned(let group, let pinned):
            setPinned([item(group: group)], pinned)
        case .dropOnLayoutSection(let ids, let section, let index):
            layoutMove(items(ids), section, index)
        case .layout(.itemMove(let id, let section, let index)):
            layoutMove([id.rawValue], section, index)
        default:
            return false
        }
        return true
    }

    /// Reprojects the accepted create placement before the next display pass. Only `shown` and its adopts: the live
    /// set and the connected remotes stay `show`'s, so a remote that dropped since cannot read as closed workspaces.
    public func reshow(live: [SidebarDocWorkspaceRef]) {
        let next = projection(live: live)
        shownVersion = version
        if next != shown { shown = next }
        if let next, !next.unplaced.isEmpty { adopt(next.unplaced) }
    }
}
