public import CmuxNextActions

// The agent pane's actions. Descriptors live in CmuxNextActions
// (`ActionCatalog+Agents`), so the palette, menus, the tab strip's new-tab
// menu, shortcuts (`shortcuts.palette.newAgentChat`) and the CLI
// (`cmux agent new-chat`) all come from the registry; this binds handlers.

extension ActionID {
    /// New Agent Chat: opens an agent tab.
    public static let newAgentChat: ActionID = "palette.newAgentChat"
    /// Open File: a file in a tab of the pane or in the text editor
    /// (`AgentPaneFileOpening`).
    public static let fileOpen: ActionID = "file.open"
}

extension ActionRegistry {
    /// Binds every agent pane action. `openNewChat` opens an agent tab in
    /// the invocation's pane (the focused pane when it has no target).
    /// Returns false when a descriptor is missing from the catalog.
    @discardableResult
    public func bindAgentPane(openNewChat: @escaping @MainActor (ActionInvocation) -> Void) -> Bool {
        bind(.newAgentChat, invoke: openNewChat)
    }
}
