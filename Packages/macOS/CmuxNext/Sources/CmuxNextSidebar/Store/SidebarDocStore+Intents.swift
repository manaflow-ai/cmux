import Foundation

extension SidebarDocStore {
    /// Sends a move intent as one document move (sidebar-v2 S4): a list
    /// reorder or group move (`DropPosition`, counted without the moved
    /// items, becomes an anchor next to a sibling the person saw), a band
    /// drop or reorder, Pin and Unpin (the old "pin group" is plain Pin: the
    /// group moves into Pinned). A group's collapse is client view state.
    /// False: not a move (the older path handles it).
    public func handle(_ intent: SidebarIntent, model: SidebarModel, drag: SidebarDocDrag, pinTitle: String, unpinTitle: String) -> Bool {
        let title = Self.moveTitle
        // A workspace the document does not place yet moves with its adopt in the same `sidebar.apply`.
        var adopt: [[String: Any]] = []
        func items(_ ids: [WorkspaceID]) -> [String] { Self.items(ids, drag: drag, adopt: &adopt) }
        func move(_ moving: [String], to target: SidebarDocTarget, title: String) {
            // main-actor-ok: one SidebarDocTarget (section, parent, before, after, index), fixed size.
            guard !adopt.isEmpty, let to = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) else {
                return self.move(moving, to: target, title: title)
            }
            send(ops: adopt + [["op": "move", "items": moving, "to": to]], title: title)
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
            guard let target = drag.target(position, moving: moving, model: model) else { return false }
            move(moving, to: target, title: title)
        case .reorderGroup(let group, let index):
            guard let section = model.sections.first(where: { $0.nodes.contains { $0.id == .group(group) } }),
                  let target = drag.target(DropPosition(section: section.id, index: index), moving: [group.rawValue], model: model) else { return false }
            move([group.rawValue], to: target, title: title)
        case .move(let ids, let group):
            guard let section = records.items[group.rawValue]?.section else { return false }
            move(items(ids), to: SidebarDocTarget(section: section, parent: group.rawValue), title: title)
        case .setPinned(let ids, let pinned):
            setPinned(items(ids), pinned)
        case .setGroupPinned(let group, let pinned):
            setPinned([group.rawValue], pinned)
        case .dropOnLayoutSection(let ids, let section, let index):
            layoutMove(items(ids), section, index)
        case .layout(.itemMove(let id, let section, let index)):
            layoutMove([id.rawValue], section, index)
        default:
            return false
        }
        return true
    }

    /// Places workspaces `ids` at list `position` (counted without them) as
    /// part of their create (`workspaces.newPlacement`, New Workspace Above
    /// or Below) or of a drop from another window: one `sidebar.apply` with
    /// the adopt of each one the document does not place yet, and no undo
    /// step (a placement, not a move the person made here). The mirror has it
    /// at once; the caller rebuilds `shown` (`reshow`). False: no target, or
    /// the mirror refused it (no refusal shows: the person did not ask for it).
    public func place(_ ids: [WorkspaceID], at position: DropPosition, model: SidebarModel, drag: SidebarDocDrag) -> Bool {
        var adopt: [[String: Any]] = []
        let moving = Self.items(ids, drag: drag, adopt: &adopt)
        // main-actor-ok: one SidebarDocTarget (section, parent, before, after, index), fixed size.
        guard !moving.isEmpty, let target = drag.target(position, moving: moving, model: model),
              let to = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) else { return false }
        do {
            try sendChecked(ops: adopt + [["op": "move", "items": moving, "to": to]], title: Self.moveTitle, undoable: false)
        } catch {
            return false
        }
        return true
    }

    /// Rebuilds `shown` over `live` now (and asks to adopt what it lacks): a
    /// change the caller just sent shows in the sidebar's next rebuild, not
    /// one observation turn later. Only `show` (the follow loop, with the
    /// connected machines of now) sends closes for workspaces that left.
    public func reshow(live: [SidebarDocWorkspaceRef]) {
        let next = projection(live: live)
        if next != shown { shown = next }
        if let next, !next.unplaced.isEmpty { adopt(next.unplaced) }
    }

    /// The document items of `ids`; a workspace the document does not place
    /// yet gets its adopt op in `adopt` and the id that adopt gives it.
    private static func items(_ ids: [WorkspaceID], drag: SidebarDocDrag, adopt: inout [[String: Any]]) -> [String] {
        ids.compactMap { id in
            if let item = drag.item(.workspace(id)) { return item }
            guard let ref = drag.adoptRef(id) else { return nil }
            adopt.append(["op": "adopt", "refs": [ref]])
            return adoptedID(SidebarDocWorkspaceRef(sessionID: ref["session_id"] as? String ?? "", workspaceID: ref["workspace_id"] as? String ?? ""))
        }
    }
}
