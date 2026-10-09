import AppKit
import CmuxNextDesign

// The group editor (cx-rcby): the chip, its more button, a right-click on
// the header, Return on a focused header, the Rename action and a new group
// all open the one editor bubble under the chip. Name and color edits go out
// as intents; an action row goes to the App (the action registry).
@MainActor
struct SidebarGroupEditing {
    let list: SidebarListView

    /// The id of the editor's trailing row that shows the group's full menu.
    static let moreActionsItem = "sidebar.group.moreActions"

    /// The editor's rows when the App gives none: the shared group actions.
    static func standardItems() -> [[SidebarGroupEditorItem]] {
        [
            [
                SidebarGroupEditorItem(id: "workspaceGroup.newWorkspace", title: GroupEditorStrings.newWorkspace, symbol: "plus.square.on.square"),
                SidebarGroupEditorItem(id: "workspaceGroup.moveToNewWindow", title: GroupEditorStrings.moveToNewWindow, symbol: "macwindow.badge.plus"),
                SidebarGroupEditorItem(id: "workspaceGroup.closeWorkspaces", title: GroupEditorStrings.close, symbol: "xmark.square"),
            ],
            [
                SidebarGroupEditorItem(id: "workspaceGroup.ungroup", title: GroupEditorStrings.ungroup, symbol: "square.stack.3d.up.slash"),
                SidebarGroupEditorItem(id: "workspaceGroup.delete", title: GroupEditorStrings.delete, symbol: "trash"),
                SidebarGroupEditorItem(id: moreActionsItem, title: GroupEditorStrings.moreActions, symbol: "ellipsis.circle"),
            ],
        ]
    }

    /// Wires the editor to the model (once, from `init`).
    func wire() {
        let editor = list.groupEditor
        editor.onRename = { [weak list] id, name in list?.model.send(.renameGroup(id, name)) }
        editor.onColor = { [weak list] id, color in
            list?.model.send(.setGroupColor(id, color))
            list?.reload(animated: true)
        }
        editor.onItem = { [weak list] id, item in
            guard let list else { return }
            // The App hears every row, More too (a menu action may add a member).
            list.onGroupEditorItem?(id, item)
            if item == Self.moreActionsItem { SidebarGroupEditing(list: list).showMenu(id) }
        }
        editor.onClose = { [weak list, weak editor] id in
            guard let list else { return }
            for case let header as GroupHeaderRowView in list.rowViews.values { header.isEditing = false }
            list.model.send(.groupEditorEnded(id))
            list.reload(animated: true)
            list.window?.makeFirstResponder(editor?.previousResponder ?? list)
        }
    }

    /// Opens the editor under the group's chip. A hidden sidebar, a drag or
    /// a group not shown opens nothing.
    func open(_ id: GroupID) {
        guard list.groups[id] != nil, let window = list.window, list.model.presentation == .shown, list.drag == nil else { return }
        // A click whose mouse-down closed this group's editor toggles it closed.
        if list.groupEditor.closedByThisClick(id, at: NSApp.currentEvent?.timestamp) { return }
        if let row = list.displayed.row(for: .group(id)) { list.scrollToVisible(list.frame(for: row)) }
        list.realizeVisibleRows()
        guard let group = list.groups[id], let view = list.rowViews[.group(id)] as? GroupHeaderRowView else { return }
        view.layoutSubtreeIfNeeded()
        // The row's settled frame: a group made a moment ago may still be moving in.
        let rowFrame = list.displayed.row(for: .group(id)).map(list.frame(for:)) ?? view.frame
        let chip = view.labelFrame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        let anchor = window.convertToScreen(list.convert(chip, to: nil))
        list.hoverCards.dismiss(.click)
        let responder = window.firstResponder
        list.groupEditor.show(group, items: list.groupEditorItems?(id) ?? Self.standardItems(), anchor: anchor, parent: window,
                              themeAnchor: list)
        list.groupEditor.previousResponder = responder
        view.isEditing = true
    }

    /// Opens the editor for the group `member` is in (a group a drop just made).
    func open(containing member: WorkspaceID) {
        guard let group = list.groups.values.first(where: { $0.workspaces.contains { $0.id == member } }) else { return }
        open(group.id)
    }

    /// The group's full menu (every group action), under its chip.
    private func showMenu(_ id: GroupID) {
        guard let menu = list.contextMenuProvider?(.group(id)), let view = list.rowViews[.group(id)] as? GroupHeaderRowView else { return }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: view.labelFrame.minX, y: view.labelFrame.maxY + Metrics.space1), in: view)
    }

    /// Keeps the open editor with its chip: a chip scrolled out of view closes it.
    func followScroll() {
        guard let shown = list.groupEditor.shownGroup else { return }
        let visible = list.enclosingScrollView?.contentView.bounds ?? list.bounds
        guard let row = list.displayed.row(for: .group(shown)), visible.intersects(list.frame(for: row)) else { return list.groupEditor.hide() }
    }

    /// Whether `point` (list coordinates) is on the group's name, off its chevron.
    func isOnChip(_ point: NSPoint, group: GroupID) -> Bool {
        guard let view = list.rowViews[.group(group)] as? GroupHeaderRowView else { return false }
        let local = list.convert(point, to: view)
        return view.nameHitFrame.contains(local) && !view.disclosureFrame.contains(local)
    }

    /// A group the store gave a new id (the home daemon names a group the
    /// sidebar made) keeps its header view: the new key takes the old view,
    /// so the group moves once instead of leaving and arriving again.
    func adoptReidentified(from old: SidebarLayout, to new: SidebarLayout) {
        for row in new.rows {
            guard case let .group(id) = row.key, old.row(for: row.key) == nil, list.rowViews[row.key] == nil,
                  let members = list.groups[id].map({ Set($0.workspaces.map(\.id)) }), !members.isEmpty else { continue }
            let previous = old.rows.first { candidate in
                guard case let .group(oldID) = candidate.key, new.row(for: candidate.key) == nil, list.rowViews[candidate.key] != nil else { return false }
                return old.rows.contains { member in
                    guard member.group == oldID, case let .workspace(workspace) = member.key else { return false }
                    return members.contains(workspace)
                }
            }
            guard let previous, let view = list.rowViews.removeValue(forKey: previous.key) else { continue }
            if case let .group(oldID) = previous.key, list.focusedGroup == oldID { list.focusedGroup = id }
            view.key = row.key
            view.configuredContent = nil
            list.rowViews[row.key] = view
            list.wire(view, key: row.key)
        }
    }
}
