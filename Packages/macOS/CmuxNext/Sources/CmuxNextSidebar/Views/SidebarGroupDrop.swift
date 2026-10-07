import AppKit

/// Drag to group in a list (spec 1780d02): a loose row's onto band groups
/// at once, with sticky edges (`SidebarGroupBand`); the drop makes a named,
/// colored group and renames it in place. Cmd-Z puts grouped rows back
/// where the drag took them from.
@MainActor enum SidebarGroupDrop {
    /// Keeps a workspace drag's onto-drop while the card's centre stays in
    /// the band's sticky edges; otherwise `resolved` (nil keeps the last).
    static func gate(_ list: SidebarListView, _ drag: SidebarListDrag, card: CGRect, resolved: DropTarget??) -> DropTarget?? {
        guard case let .workspaces(ids) = drag.payload else { return resolved }
        let hit = SidebarGroupBand.hit(y: card.midY, rows: list.displayed.rows, hidden: drag.hiddenKeys, dragged: ids,
                                       sections: list.model.sections)
        if let anchor = drag.band.update(hit) { return .some(.ontoWorkspace(anchor)) }
        return resolved
    }

    /// Joins `ids` to `group`, with Cmd-Z.
    static func join(_ list: SidebarListView, _ ids: [WorkspaceID], _ group: GroupID, origin: DropPosition?) {
        list.model.send(.move(ids, toGroup: group))
        registerUndo(list, ids, origin: origin, anchor: nil)
    }

    /// Groups `ids` with `anchor`, at the anchor's row, as a named and colored group, with Cmd-Z.
    @discardableResult
    static func group(_ list: SidebarListView, _ ids: [WorkspaceID], onto anchor: WorkspaceID, origin: DropPosition?) -> GroupID {
        let group = GroupID.make(), sections = list.model.sections
        list.model.send(.createGroup(group, name: SidebarGroup.named(""), color: SidebarGroupBand.newGroupColor(in: sections),
                                     workspaces: [anchor] + ids, anchor: anchor))
        registerUndo(list, ids, origin: origin, anchor: anchor)
        return group
    }

    /// Registers Cmd-Z for a drop that grouped `ids`.
    static func registerUndo(_ list: SidebarListView, _ ids: [WorkspaceID], origin: DropPosition?, anchor: WorkspaceID?) {
        guard let origin, let undoManager = list.window?.undoManager else { return }
        let record = SidebarGroupUndo(list: list, ids: ids, origin: origin, anchor: anchor)
        // The record is the target and the retained object, so it lives as long as the undo entry.
        undoManager.registerUndo(withTarget: record, selector: #selector(SidebarGroupUndo.undo(_:)), object: record)
        undoManager.setActionName(anchor == nil ? Strings.moveToGroup : SidebarGroup.named(""))
    }
}

/// One drag-to-group drop's undo: ungroup the new group around `anchor`
/// (found by member, since the store may give it a new id), then put `ids`
/// back at `origin`.
@MainActor final class SidebarGroupUndo: NSObject {
    weak var list: SidebarListView?
    let ids: [WorkspaceID]
    let origin: DropPosition
    let anchor: WorkspaceID?

    init(list: SidebarListView, ids: [WorkspaceID], origin: DropPosition, anchor: WorkspaceID?) {
        self.list = list
        self.ids = ids
        self.origin = origin
        self.anchor = anchor
    }

    @objc func undo(_ sender: Any?) {
        guard let list else { return }
        let model = list.model
        if let anchor, let group = model.sections.flatMap(\.nodes).lazy.compactMap({ node -> GroupID? in
            guard case let .group(group) = node, group.workspaces.contains(where: { $0.id == anchor }) else { return nil }
            return group.id
        }).first {
            model.send(.ungroup(group))
        }
        model.send(.reorder(ids, to: origin))
        list.reload(animated: true)
    }
}
