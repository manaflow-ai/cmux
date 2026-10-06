extension AgentPaneModel {
    /// The app actions the chat header runs on its tab (`pane.action`): the Terminal and Browser
    /// splits and the "..." menu's tab verbs.
    public static let headerActions: Set<String> = [
        "splitRight", "splitBrowserRight", "renameTab", "palette.toggleTabPin",
        "moveSurfaceToPaneRight", "palette.moveTabToNewWorkspace", "closeTab",
    ]

    /// `pane.action` runs a listed action on a chat (never the New Tab page); `pane.tabState`
    /// reads the tab's pin.
    func respondToHeader(_ request: AgentPaneRequest) -> [String: Any] {
        switch request {
        case .paneAction(let id, let cwd):
            guard newTab == nil, Self.headerActions.contains(id), let onPaneAction else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.action")
            }
            onPaneAction(id, cwd)
            return AgentPaneReply.success()
        case .tabState:
            guard let onTabState else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.tabState")
            }
            return AgentPaneReply.success(onTabState())
        default:
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request")
        }
    }
}
