import AppKit
import CmuxNextWakeups

/// Drag to group (`SidebarGroupDwell`) in a list: a workspace drag reorders
/// from the outer quarters of the row under the pointer and groups from its
/// middle after a dwell. Cmd-Z puts grouped rows back where the drag took them from.
@MainActor enum SidebarGroupDrop {
    static func update(_ list: SidebarListView, _ drag: SidebarListDrag, ids: [WorkspaceID], pointerY: CGFloat) {
        drag.pointerY = pointerY
        let model = list.model, displayed = list.displayed
        let hit = SidebarGroupDwell.hit(y: pointerY, rows: displayed.rows, hidden: drag.hiddenKeys, dragged: ids, sections: model.sections)
        let target: DropTarget?
        switch drag.dwell.update(hit, now: list.dragClock()) {
        case let .armed(group):
            drag.dwellTimer.cancel()
            target = group
        case .pending:
            // The rows hold still while the pointer waits over a middle.
            if !drag.dwellTimer.isScheduled {
                drag.dwellTimer.schedule(after: .milliseconds(Int(SidebarGroupDwell.dwell * 1000))) { @MainActor [weak list] in
                    if let list { dwellElapsed(list) }
                }
            }
            target = drag.lastPosition.map(DropTarget.position) ?? drag.target
        case .none:
            drag.dwellTimer.cancel()
            guard let baseY = DropResolver.baseY(forDisplayY: pointerY, gapY: displayed.gapY, gapHeight: displayed.gapShift) else { return }
            let base = SidebarLayout.make(sections: model.sections, metrics: list.metrics, options: list.options(includeGap: false))
            target = DropResolver.resolve(y: baseY, payload: drag.payload, base: base, sections: model.sections,
                                          ungroupedFirst: model.ungroupedFirst, groupsOnto: false)
        }
        guard target != drag.target else { return }
        drag.target = target
        drag.lift.setRefused(target == nil)
        list.reload(animated: true)
    }

    /// The dwell deadline: the pointer has rested over a row's middle.
    static func dwellElapsed(_ list: SidebarListView) {
        guard let drag = list.drag, case let .workspaces(ids) = drag.payload else { return }
        update(list, drag, ids: ids, pointerY: drag.pointerY)
    }

    /// Registers Cmd-Z for a drop that grouped `ids`.
    static func registerUndo(_ list: SidebarListView, _ ids: [WorkspaceID], origin: DropPosition?, anchor: WorkspaceID?) {
        guard let origin, let undoManager = list.window?.undoManager else { return }
        let record = SidebarGroupUndo(list: list, ids: ids, origin: origin, anchor: anchor)
        // The record is the target and the retained object, so it lives as long as the undo entry.
        undoManager.registerUndo(withTarget: record, selector: #selector(SidebarGroupUndo.undo(_:)), object: record)
        undoManager.setActionName(anchor == nil ? Strings.moveToGroup : Strings.newGroupName)
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
