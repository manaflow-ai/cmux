import AppKit
import CmuxNextDesign
import CmuxNextIcons

// The group editor (cx-rcby): the chip, its more button, a right-click on
// the header, Return on a focused header, the Rename action and a new group
// all open the one editor bubble under the chip. Name and color edits go out
// as intents; an action row goes to the App (the action registry).
@MainActor
struct SidebarGroupEditing {
    let list: SidebarListView

    /// The id of the editor's trailing row that shows the group's full menu.
    static let moreActionsItem = "sidebar.group.moreActions"
    /// Not a row: the editor is about to give way to another picker (the
    /// color panel) that still edits this group, so a new empty group stays.
    static let keepGroupItem = "sidebar.group.keep"

    /// The editor's rows when the App gives none: the shared group actions. Pin and Move to Top
    /// sit in the editor itself (Lawrence 2026-10-20); the rest are in the header's right-click
    /// menu, which is flat, so the editor has no More Group Actions row. `pinned` titles the
    /// pin row as the change it makes.
    static func standardItems(pinned: Bool = false) -> [[SidebarGroupEditorItem]] {
        [
            [
                SidebarGroupEditorItem(id: "workspaceGroup.newWorkspace", title: GroupEditorStrings.newWorkspace, icon: .workspaceNew),
                SidebarGroupEditorItem(id: "workspaceGroup.moveToNewWindow", title: GroupEditorStrings.moveToNewWindow, icon: .windowNew),
                SidebarGroupEditorItem(id: "workspaceGroup.closeWorkspaces", title: GroupEditorStrings.close, icon: .actionClose),
            ],
            [
                SidebarGroupEditorItem(id: "workspaceGroup.togglePin", title: pinned ? GroupEditorStrings.unpin : GroupEditorStrings.pin,
                                       icon: .actionPin),
                SidebarGroupEditorItem(id: "workspaceGroup.moveToTop", title: GroupEditorStrings.moveToTop, icon: .navPreviousMatch),
            ],
            [
                SidebarGroupEditorItem(id: "workspaceGroup.ungroup", title: GroupEditorStrings.ungroup, icon: .groupUngroup),
                SidebarGroupEditorItem(id: "workspaceGroup.delete", title: GroupEditorStrings.delete, icon: .actionDelete),
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
        // The bubble is its own window: the keys stay where the click put them.
        editor.onClose = { [weak list] id in
            guard let list else { return }
            for case let header as GroupHeaderRowView in list.rowViews.values { header.isEditing = false }
            list.model.send(.groupEditorEnded(id))
            list.reload(animated: true)
        }
    }

    /// What opened the group editor, which says where it opens (u2250: next to
    /// the control the user clicked, not at the header bar's leading edge).
    enum Opener {
        /// The group's name (Return, Rename, a new group): under the name, on its leading edge.
        case name
        /// The header's more button: under the button, on its trailing edge.
        case moreButton
        /// A point in list coordinates: at that point.
        case pointer(NSPoint)
    }

    /// Opens the editor next to what opened it (`opener`). A hidden sidebar,
    /// a drag or a group not shown opens nothing.
    func open(_ id: GroupID, from opener: Opener = .name) {
        // A remote group has no name or color of its own: Return, the menu and the name show its machine's menu.
        if SidebarGroup.hostMachine(id) != nil { return showMenu(id) }
        guard list.groups[id] != nil, let window = list.window, list.model.presentation == .shown, list.drag == nil else { return }
        // A click whose mouse-down closed this group's editor toggles it closed.
        if list.groupEditor.closedByThisClick(id, event: NSApp.currentEvent) { return }
        if let row = list.displayed.groupRow(id) { list.scrollToVisible(list.frame(for: row)) }
        list.realizeVisibleRows()
        guard let group = list.groups[id] else { return }
        guard let view = list.rowViews[.group(id)] as? GroupHeaderRowView else { return openAtStandingRow(group, window: window) }
        view.layoutSubtreeIfNeeded()
        // The row's settled frame: a group made a moment ago may still be moving in.
        let rowFrame = list.displayed.row(for: .group(id)).map(list.frame(for:)) ?? view.frame
        let control: PopupAnchor = switch opener {
        case .name: PopupAnchor(rect: view.nameHitFrame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY), edge: .leading)
        case .moreButton: PopupAnchor(rect: view.moreButton.frame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY), edge: .trailing)
        case let .pointer(point): PopupAnchor(point: point)
        }
        let anchor = PopupAnchor(rect: window.convertToScreen(list.convert(control.rect, to: nil)), edge: control.edge, gap: control.gap)
        list.hoverCards.dismiss(.click)
        list.groupEditor.show(group, items: list.groupEditorItems?(id) ?? Self.standardItems(pinned: group.isPinned), anchor: anchor, parent: window,
                              themeAnchor: list)
        view.isEditing = true
    }

    /// The row a group drawn as its one row draws (`SidebarLayout+SoleMember`): it has no header.
    /// The editor of a group drawn as its one row, at that row's title: Rename from its menu, Return from the keyboard.
    private func openAtStandingRow(_ group: SidebarGroup, window: NSWindow) {
        guard let row = list.displayed.groupRow(group.id), let view = list.rowViews[row.key] else { return }
        let rowFrame = list.frame(for: row)
        let title = view.titleFrame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        let anchor = PopupAnchor(rect: window.convertToScreen(list.convert(title, to: nil)), edge: .leading)
        list.hoverCards.dismiss(.click)
        list.groupEditor.show(group, items: list.groupEditorItems?(group.id) ?? Self.standardItems(pinned: group.isPinned), anchor: anchor,
                              parent: window, themeAnchor: list)
    }

    /// Opens the editor for the group `member` is in (a group a drop just made).
    func open(containing member: WorkspaceID) {
        guard let group = list.groups.values.first(where: { $0.workspaces.contains { $0.id == member } }) else { return }
        open(group.id)
    }

    /// The group's full menu under its more button, on the button's trailing
    /// edge (the editor's More Group Actions row, VoiceOver's menu action).
    func showMenu(_ id: GroupID) {
        let target = SidebarGroup.hostMachine(id).map { SidebarContextTarget.section(.machine($0)) } ?? .group(id)
        guard let menu = list.contextMenuProvider?(target) else { return }
        guard let view = list.rowViews[.group(id)] as? GroupHeaderRowView else {
            // A group drawn as its one row: on that row's trailing edge.
            guard let row = list.displayed.groupRow(id), let view = list.rowViews[row.key] else { return }
            return list.menuPresenter(menu, PopupAnchor(rect: view.bounds, edge: .trailing), view)
        }
        list.menuPresenter(menu, PopupAnchor(rect: view.moreButton.frame, edge: .trailing), view)
    }

    /// Keeps the open editor with its chip: a chip scrolled out of view closes it.
    func followScroll() {
        guard let shown = list.groupEditor.shownGroup else { return }
        let visible = list.enclosingScrollView?.contentView.bounds ?? list.bounds
        guard let row = list.displayed.groupRow(shown), visible.intersects(list.frame(for: row))
        else { return list.groupEditor.hide() }
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
        followFocus(from: old, to: new)
    }

    /// Keyboard focus on a group the store gave a new id moves to the new id, whatever row the group draws as: a group
    /// drawn as its one row (`SidebarLayout+SoleMember`) keeps its member's row, so no header view moves above.
    private func followFocus(from old: SidebarLayout, to new: SidebarLayout) {
        guard let focused = list.focusedGroup, list.groups[focused] == nil, new.groupRow(focused) == nil else { return }
        let members = Set(old.rows.compactMap { row -> WorkspaceID? in
            guard row.group == focused, case let .workspace(id) = row.key else { return nil }
            return id
        })
        guard !members.isEmpty,
              let moved = list.groups.values.first(where: { $0.workspaces.contains { members.contains($0.id) } }) else { return }
        list.focusedGroup = moved.id
    }
}

extension SidebarListView {
    /// Group `id`'s header actions for the one row it draws as, through the paths the header's own use (`wire`).
    func standingGroupAccess(_ id: GroupID) -> StandingGroupAccess {
        StandingGroupAccess(
            expanded: groups[id]?.isCollapsed == false,
            toggle: { [weak self] in
                self?.model.noteUserIntent()
                self?.model.send(.toggleCollapse(.group(id)))
            },
            edit: { [weak self] in self?.groupEditing.open(id, from: .moreButton) },
            menu: { [weak self] in self?.groupEditing.showMenu(id) },
            add: onGroupEditorItem == nil ? nil : { [weak self] in self?.onGroupEditorItem?(id, "workspaceGroup.newWorkspace") }
        )
    }
}
