/// The app side of the chat header (`pane.action`, `pane.tabState`): runs a
/// ``AgentPaneModel/headerActions`` id on the chat's tab, a split in `cwd` when given,
/// and reads the tab's state the "..." menu's labels show (`{pinned}`).
public struct AgentPaneHeaderHooks {
    public var run: @MainActor (String, String?) -> Void
    public var tabState: @MainActor () -> [String: Any]

    public init(run: @escaping @MainActor (String, String?) -> Void, tabState: @escaping @MainActor () -> [String: Any]) {
        self.run = run
        self.tabState = tabState
    }
}

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
            guard newTab == nil, Self.headerActions.contains(id), let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.action")
            }
            header.run(id, cwd)
            return AgentPaneReply.success()
        case .tabState:
            guard let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.tabState")
            }
            return AgentPaneReply.success(header.tabState())
        default:
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request")
        }
    }
}
