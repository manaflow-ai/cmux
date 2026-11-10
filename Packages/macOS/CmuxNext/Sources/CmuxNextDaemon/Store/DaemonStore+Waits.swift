/// What a wait for one tab or one workspace reads (main-thread-scheduling.md section 3, O9): each wait re-runs its
/// lookup under observation until it matches or its time limit ends.
extension DaemonStore {
    /// The tab on `surface`, with its pane and workspace, once the tree lists it.
    public func locatedTab(surface: SurfaceID) -> (tab: TabModel, pane: PaneModel, workspace: WorkspaceModel)? {
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let tab = pane.tabs.first(where: { $0.surface == surface }) { return (tab, pane, workspace) }
                }
            }
        }
        return nil
    }

    /// Whether the workspace with key `key` lists a conversation tab now.
    public func listsConversationTab(inWorkspace key: String) -> Bool {
        workspaces.first(where: { $0.key?.rawValue == key })?.screens
            .flatMap(\.panes).flatMap(\.tabs).contains(where: { $0.kind == .conversation }) ?? false
    }
}
