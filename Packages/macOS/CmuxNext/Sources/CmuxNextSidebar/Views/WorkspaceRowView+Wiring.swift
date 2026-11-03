import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// The row's callbacks for workspace `id` in `list`, set on every dequeue
    /// (`SidebarListView.wire`) so a recycled view never keeps a previous
    /// row's target.
    func wire(_ id: WorkspaceID, in list: SidebarListView) {
        onClose = { [weak list] in list?.model.send(.close([id])) }
        onMore = list.contextMenuProvider == nil ? nil : { [weak list] in list.map { SidebarRowMenu(list: $0).show(for: id) } }
        onSelect = { [weak list] in list?.model.click(id) }
        // Redraw now: left to the tree's observation, the fold would wait
        // out the calm-movement hold until the pointer leaves the sidebar.
        onToggleTree = { [weak list] in SidebarSessionTree.shared.toggle(id); list?.reload(animated: true) }
        onToggleAudio = { [weak list] in list?.model.send(.toggleWorkspaceAudio(id)) }
        // An expanded row's hover pin (cx-13w3): nil while the App offers none.
        isPinned = { [weak list] in list?.model.workspacePin?.isPinned(id) }
        onPin = { [weak list] in list?.model.workspacePin?.toggle(id) }
    }

    /// Reads the agent mark, presence dot, row badge and stack size settings;
    /// one shared observation (`SidebarTunablesWatch`) redraws the live rows
    /// when one changes, not one new registration per configure.
    func observedTunables() -> SidebarTunablesWatch.Values {
        SidebarTunablesWatch.shared.values(for: self)
    }
}
