import AppKit
// Row view reuse through `rowPool`: views exist only for rows near the
// viewport, and leaving rows return to the pool.
extension SidebarListView {
    /// `rebinding`: with no parked view of `key`, take another parked row's
    /// view of the same kind (scroll realization only: the view is placed,
    /// never animated, so nothing flies in from its old row, cx-ai79).
    func dequeue(_ key: SidebarRowKey, rebinding: Bool = false) -> SidebarRowView {
        let view = rowPool.take(for: key, rebinding: rebinding)
        wire(view, key: key)
        return view
    }
    func recycle(_ view: SidebarRowView) {
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
            view.onMore = { [weak self] in self?.groupEditing.showMenu(id) } // VoiceOver's full menu; the chip and more button edit
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
}
