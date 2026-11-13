extension Intent {
    /// The intent's name in the slow request log's rollback record (``SlowRequestLog``): a fixed word
    /// per case, never a value the intent carries (a name, a color, a tab).
    var logName: String {
        switch self {
        case .moveTab: "move-tab"
        case .renameTab: "rename-tab"
        case .setTabPinned: "set-tab-pinned"
        case .renamePane: "rename-pane"
        case .renameScreen: "rename-screen"
        case .setScreenColor: "set-screen-color"
        case .setScreenIcon: "set-screen-icon"
        case .setScreenPinned: "set-screen-pinned"
        case .setDividerVisible: "set-divider-visible"
        case .renameWorkspace: "rename-workspace"
        case .setWorkspaceColor: "set-workspace-color"
        case .moveWorkspace: "move-workspace"
        case .setWorkspaceGroup: "set-workspace-group"
        case .placeWorkspace: "place-workspace"
        case .setWorkspaceGroupCollapsed: "set-workspace-group-collapsed"
        case .setTabGroupCollapsed: "set-tab-group-collapsed"
        case .setRowHeights: "set-row-heights"
        case .createTab: "create-tab"
        case .bindAgentSession: "bind-agent-session"
        case .splitPane: "split-pane"
        case .createWorkspace: "create-workspace"
        case .closeTabs: "close-tabs"
        case .dockTab: "dock-tab"
        case .closeStandInPane: "close-stand-in-pane"
        case .zoomPane: "zoom-pane"
        case .swapPanes: "swap-panes"
        }
    }
}
