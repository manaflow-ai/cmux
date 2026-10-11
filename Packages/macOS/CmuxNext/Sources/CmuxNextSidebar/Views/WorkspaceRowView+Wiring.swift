import AppKit

extension WorkspaceRowView {
    /// The row's callbacks for workspace `id` in `list`, set on every dequeue
    /// (`SidebarListView.wire`) so a recycled view never keeps a previous
    /// row's target.
    func wire(_ id: WorkspaceID, in list: SidebarListView) {
        onClose = { [weak list] in list?.model.send(.close([id])) }
        onMore = list.contextMenuProvider == nil ? nil : { [weak list] in list.map { SidebarRowMenu(list: $0).show(for: id) } }
        onSelect = { [weak list] in list?.model.click(id) }
        onToggleTabs = { [weak list] in list?.model.toggleWorkspaceTabs(id); list?.reload(animated: true) }
        // An expanded row's hover pin (cx-13w3): nil while the App offers none.
        isPinned = { [weak list] in list?.model.workspacePin?.isPinned(id) }
        onPin = { [weak list] in list?.model.workspacePin?.toggle(id) }
    }
}
