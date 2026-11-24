public import CmuxNextActions
public import CmuxNextDaemon

/// What an open of an existing session's chat answers (`agent.openSessionTab`, `agent.openSessionWorkspace`): the
/// session and the ids of the tab, pane and workspace that show it, also when the chat was already open, so a script
/// can tell where the chat is (ask-a0466e9c05: an open of a shown session answered success with nothing).
public struct AgentSessionOpenAnswer {
    public init() {}
    /// The answer's fields; a nil tab or pane (a keyed workspace whose first tab is still in flight) is left out.
    @MainActor public static func fields(session: String, tab: TabModel?, tabID: String? = nil, pane: PaneModel?,
                                         workspace: WorkspaceModel?) -> [String: ActionResultValue] {
        var result: [String: ActionResultValue] = ["session": .string(session)]
        if let tab = tab?.resourceID?.rawValue ?? tab?.id ?? tabID { result["tab"] = .string(tab) }
        if let pane { result["pane"] = .string(pane.resourceID?.rawValue ?? pane.id) }
        if let workspace {
            result["workspace"] = .string(workspace.resourceID?.rawValue ?? workspace.id)
            if let key = workspace.key { result["workspace_key"] = .string(key.rawValue) }
        }
        return result
    }

    /// True when `workspace` is the one `named` names by key or id, or `named` is nil (any workspace).
    @MainActor public static func holds(_ workspace: WorkspaceModel, _ named: String?) -> Bool {
        named == nil || workspace.key?.rawValue == named || workspace.id == named
    }
}
