public import CmuxNextActions

// The agent pane's actions. Descriptors live in CmuxNextActions
// (`ActionCatalog+Agents`), so the palette, menus, the tab strip's new-tab
// menu, shortcuts (`shortcuts.palette.newAgentChat`) and the CLI
// (`cmux agent new-chat`) all come from the registry; this binds handlers.

extension ActionID {
    /// New Agent Chat: opens an agent tab.
    public static let newAgentChat: ActionID = "palette.newAgentChat"
    /// Show ACP Inspector: toggles the agent pane's ACP inspector
    /// (`AgentPaneView.toggleInspector`).
    public static let toggleAcpInspector: ActionID = "agentPane.toggleInspector"
}

extension ActionRegistry {
    /// Binds every agent pane action. `openNewChat` opens an agent tab in
    /// the invocation's pane (the focused pane when it has no target).
    /// Returns false when a descriptor is missing from the catalog.
    @discardableResult
    public func bindAgentPane(openNewChat: @escaping @MainActor (ActionInvocation) -> Void) -> Bool {
        bind(.newAgentChat, invoke: openNewChat)
    }

    /// Binds Show ACP Inspector. `toggle` toggles the inspector of the agent
    /// tab shown in the invocation's pane (the focused pane when it has no
    /// target). Returns false when the descriptor is missing from the catalog.
    @discardableResult
    public func bindAgentPaneInspector(toggle: @escaping @MainActor (ActionInvocation) -> Void) -> Bool {
        bind(.toggleAcpInspector, invoke: toggle)
    }
}
