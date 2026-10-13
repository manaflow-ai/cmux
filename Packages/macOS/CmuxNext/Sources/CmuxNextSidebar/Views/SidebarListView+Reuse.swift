import AppKit
// Row view reuse through `rowPool`: views exist only for rows near the
// viewport, and leaving rows return to the pool.
extension SidebarListView {
    func dequeue(_ key: SidebarRowKey) -> SidebarRowView {
        let view = rowPool.take(for: key)
        wire(view, key: key)
        return view
    }
    func recycle(_ view: SidebarRowView) {
        rowSprings.cancel(view)
        view.removeFromSuperview()
        rowPool.put(view)
    }
    /// Per-key callbacks, set on every dequeue so recycled views never keep
    /// a previous row's target.
    func wire(_ view: SidebarRowView, key: SidebarRowKey) {
        switch (key, view) {
        case let (.workspace(id), view as WorkspaceRowView):
            view.wire(id, in: self)
        case let (.tab(workspaceID, tabID), view as SidebarTabRowView):
            view.onSelect = { [weak self] in
                self?.model.send(.selectTab(workspace: workspaceID, tab: tabID))
            }
        case let (.group(id), view as GroupHeaderRowView):
            view.onMore = { [weak self] in self?.groupEditing.showMenu(id) } // the full menu (cx-a9h6); the chip edits
            view.onEdit = { [weak self] in self?.groupEditing.open(id) }
            // The header's + runs the editor's New Workspace in Group (one action path).
            view.onAdd = onGroupEditorItem == nil ? nil : { [weak self] in self?.onGroupEditorItem?(id, "workspaceGroup.newWorkspace") }
            view.isEditing = groupEditor.shownGroup == id
            view.isKeyboardFocused = showsFocusRing && focusedGroup == id
        case let (.section(sectionID), view as SectionHeaderRowView):
            if case let .machine(machine) = sectionID {
                view.allowsAdd = true
                view.onAdd = { [weak self] in self?.model.send(.newWorkspace(machine: machine, group: nil)) }
            } else {
                view.allowsAdd = false
                view.onAdd = nil
            }
        default:
            break
        }
    }
    /// Adds views for rows scrolled into range and drops far-away ones.
    func realizeVisibleRows() {
        guard !isShiftingViewport else { return }
        groupEditing.followScroll()
        let realize = realizationRect()
        for row in displayed.rows where rowViews[row.key] == nil {
            let target = frame(for: row)
            guard target.intersects(realize) else { continue }
            let view = dequeue(row.key)
            view.targetSize = target.size
            configure(view, row: row, animated: false)
            addSubview(view, positioned: .above, relativeTo: decorations)
            RowMotion.place(view, at: target, opening: openingRows[row.key] != nil, hidden: suppressed.contains(row.key), in: self)
            rowViews[row.key] = view
        }
        pruneOffscreen()
        updateHover()
    }
    func pruneOffscreen() {
        let keepRect = realizationRect().insetBy(dx: 0, dy: -SidebarStyle.overscan)
        for row in displayed.rows {
            guard let view = rowViews[row.key], !frame(for: row).intersects(keepRect),
                  inlineRename.session?.key != row.key, row.key != groupEditor.shownGroup.map(SidebarRowKey.group) else { continue }
            recycle(view)
            rowViews[row.key] = nil
        }
    }
}
