import AppKit
import CmuxNextWakeups

/// Drag to group (`SidebarGroupDwell`) in a list: a workspace drag groups
/// only once the card's centre has rested in a row's onto band; until then,
/// and outside the band, the drop resolves as a reorder (spec 1780d02).
/// Cmd-Z puts grouped rows back where the drag took them from.
@MainActor enum SidebarGroupDrop {
    /// Gates a workspace drag's `resolved` drop (nil keeps the last) through the dwell.
    static func gate(_ list: SidebarListView, _ drag: SidebarListDrag, card: CGRect, resolved: DropTarget??) -> DropTarget?? {
        guard case let .workspaces(ids) = drag.payload else { return resolved }
        let hit = SidebarGroupDwell.hit(y: card.midY, rows: list.displayed.rows, hidden: drag.hiddenKeys, dragged: ids,
                                        sections: list.model.sections)
        switch drag.dwell.update(hit, now: drag.clock()) {
        case let .armed(group):
            drag.dwellTimer.cancel()
            return .some(group)
        case .pending:
            // The rows hold still while the card waits over a middle.
            if !drag.dwellTimer.isScheduled {
                drag.dwellTimer.schedule(after: .milliseconds(Int(SidebarGroupDwell.dwell * 1000))) { @MainActor [weak list] in
                    if let list { dwellElapsed(list) }
                }
            }
            return .some(drag.lastPosition.map(DropTarget.position) ?? drag.target)
        case .none:
            drag.dwellTimer.cancel()
            switch resolved {
            case .some(.ontoWorkspace?), .some(.intoGroup?): return .some(drag.lastPosition.map(DropTarget.position))
            default: return resolved
            }
        }
    }

    /// The dwell deadline: the card has rested over a row's middle.
    static func dwellElapsed(_ list: SidebarListView) {
        guard let drag = list.drag else { return }
        list.updateDrag(windowPoint: drag.lastWindowPoint)
    }

    /// Joins `ids` to `group`, with Cmd-Z.
    static func join(_ list: SidebarListView, _ ids: [WorkspaceID], _ group: GroupID, origin: DropPosition?) {
        list.model.send(.move(ids, toGroup: group))
        registerUndo(list, ids, origin: origin, anchor: nil)
    }

    /// Groups `ids` with `anchor`, at the anchor's row, as a named and colored group, with Cmd-Z.
    static func group(_ list: SidebarListView, _ ids: [WorkspaceID], onto anchor: WorkspaceID, origin: DropPosition?) -> GroupID {
        let group = GroupID.make(), sections = list.model.sections
        list.model.send(.createGroup(group, name: SidebarGroup.named(""), color: SidebarGroupDwell.newGroupColor(in: sections),
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
