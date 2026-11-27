public import CmuxNextDaemon

// The Chief panel borrows the view of Home's Chief tab (user 2026-11-06): these are the tabs that may hold it.
extension WorkspaceModel {
    /// The conversation tabs of this workspace, those in a docked column first (Home's pinned Chief dock).
    public var chiefPanelTabs: [TabModel] {
        var docked: [TabModel] = []
        var others: [TabModel] = []
        for screen in screens {
            let dockPanes = Set(screen.columns.filter { $0.dock != nil }.flatMap(\.layout.paneIDs))
            for pane in screen.panes {
                let chats = pane.tabs.filter { $0.kind == .conversation }
                if dockPanes.contains(pane.handle) { docked += chats } else { others += chats }
            }
        }
        return docked + others
    }
}
