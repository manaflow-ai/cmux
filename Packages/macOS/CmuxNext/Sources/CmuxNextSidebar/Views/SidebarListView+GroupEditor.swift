import AppKit
import CmuxNextDesign

// The group editor (cx-rcby): the chip, its more button, a right-click on
// the header, Return on a focused header, the Rename action and a new group
// all open the one editor bubble under the chip. Name and color edits go out
// as intents; an action row goes to the App (the action registry).
extension SidebarListView {
    /// The id of the editor's trailing row that shows the group's full menu.
    static let groupMoreActionsItem = "sidebar.group.moreActions"

    /// The editor's rows when the App gives none: the shared group actions.
    static func standardGroupEditorItems() -> [[SidebarGroupEditorItem]] {
        [
            [
                SidebarGroupEditorItem(id: "workspaceGroup.newWorkspace", title: GroupEditorStrings.newWorkspace, symbol: "plus.square.on.square"),
                SidebarGroupEditorItem(id: "workspaceGroup.moveToNewWindow", title: GroupEditorStrings.moveToNewWindow, symbol: "macwindow.badge.plus"),
                SidebarGroupEditorItem(id: "workspaceGroup.closeWorkspaces", title: GroupEditorStrings.close, symbol: "xmark.square"),
            ],
            [
                SidebarGroupEditorItem(id: "workspaceGroup.ungroup", title: GroupEditorStrings.ungroup, symbol: "square.stack.3d.up.slash"),
                SidebarGroupEditorItem(id: "workspaceGroup.delete", title: GroupEditorStrings.delete, symbol: "trash"),
                SidebarGroupEditorItem(id: groupMoreActionsItem, title: GroupEditorStrings.moreActions, symbol: "ellipsis.circle"),
            ],
        ]
    }

    /// Wires the editor to the model (once, from `init`).
    func wireGroupEditor() {
        groupEditor.onRename = { [weak self] id, name in self?.model.send(.renameGroup(id, name)) }
        groupEditor.onColor = { [weak self] id, color in
            self?.model.send(.setGroupColor(id, color))
            self?.reload(animated: true)
        }
        groupEditor.onItem = { [weak self] id, item in
            guard let self else { return }
            if item == Self.groupMoreActionsItem { return showGroupMenu(id) }
            onGroupEditorItem?(id, item)
        }
        groupEditor.onClose = { [weak self] id in
            guard let self else { return }
            for case let header as GroupHeaderRowView in rowViews.values { header.isEditing = false }
            model.send(.groupEditorEnded(id))
            reload(animated: true)
            window?.makeFirstResponder(self)
        }
    }

    /// Opens the editor under the group's chip. A hidden sidebar, a drag or
    /// a group not shown opens nothing.
    func openGroupEditor(_ id: GroupID) {
        guard groups[id] != nil, let window, model.presentation == .shown, drag == nil else { return }
        if let row = displayed.row(for: .group(id)) { scrollToVisible(frame(for: row)) }
        realizeVisibleRows()
        guard let group = groups[id], let view = rowViews[.group(id)] as? GroupHeaderRowView else { return }
        view.layoutSubtreeIfNeeded()
        // The row's settled frame: a group made a moment ago may still be moving in.
        let rowFrame = displayed.row(for: .group(id)).map(frame(for:)) ?? view.frame
        let chip = view.labelFrame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        let anchor = window.convertToScreen(convert(chip, to: nil))
        view.isEditing = true
        hoverCards.dismiss(.click)
        groupEditor.show(group, items: groupEditorItems?(id) ?? Self.standardGroupEditorItems(), anchor: anchor, parent: window,
                         themeAnchor: self)
    }

    /// Opens the editor for the group `member` is in (a group a drop just made).
    func openGroupEditor(containing member: WorkspaceID) {
        guard let group = groups.values.first(where: { $0.workspaces.contains { $0.id == member } }) else { return }
        openGroupEditor(group.id)
    }

    /// The group's full menu (every group action), under its chip.
    private func showGroupMenu(_ id: GroupID) {
        guard let menu = contextMenuProvider?(.group(id)), let view = rowViews[.group(id)] as? GroupHeaderRowView else { return }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: view.labelFrame.minX, y: view.labelFrame.maxY + Metrics.space1), in: view)
    }

    /// Whether `point` (list coordinates) is on the group's chip, off its chevron.
    func isOnGroupChip(_ point: NSPoint, group: GroupID) -> Bool {
        guard let view = rowViews[.group(group)] as? GroupHeaderRowView else { return false }
        let local = convert(point, to: view)
        return view.labelFrame.contains(local) && !view.disclosureFrame.contains(local)
    }

    /// A group the store gave a new id (the home daemon names a group the
    /// sidebar made) keeps its header view: the new key takes the old view,
    /// so the group moves once instead of leaving and arriving again.
    func adoptReidentifiedGroups(from old: SidebarLayout, to new: SidebarLayout) {
        for row in new.rows {
            guard case let .group(id) = row.key, old.row(for: row.key) == nil, rowViews[row.key] == nil,
                  let members = groups[id].map({ Set($0.workspaces.map(\.id)) }), !members.isEmpty else { continue }
            let previous = old.rows.first { candidate in
                guard case let .group(oldID) = candidate.key, new.row(for: candidate.key) == nil, rowViews[candidate.key] != nil else { return false }
                return old.rows.contains { member in
                    guard member.group == oldID, case let .workspace(workspace) = member.key else { return false }
                    return members.contains(workspace)
                }
            }
            guard let previous, let view = rowViews.removeValue(forKey: previous.key) else { continue }
            view.key = row.key
            view.configuredContent = nil
            rowViews[row.key] = view
            wire(view, key: row.key)
        }
    }
}
