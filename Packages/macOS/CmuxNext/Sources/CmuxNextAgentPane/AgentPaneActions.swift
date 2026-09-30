public import CmuxNextActions

/// The agent pane's actions. Descriptors live in CmuxNextActions
/// (`ActionCatalog+Agents`), so the palette, menus, the tab strip's new-tab
/// menu, shortcuts (`shortcuts.palette.newAgentChat`) and the CLI
/// (`cmux agent new-chat`) all come from the registry; this binds handlers.
public enum AgentPaneActions {
    public static let newChat: ActionID = "palette.newAgentChat"

    /// Binds every agent pane action. `openNewChat` opens an agent tab in
    /// the invocation's pane (the focused pane when it has no target).
    /// Returns false when a descriptor is missing from the catalog.
    @discardableResult
    public static func bind(into registry: ActionRegistry, openNewChat: @escaping @MainActor (ActionInvocation) -> Void) -> Bool {
        registry.bind(newChat, invoke: openNewChat)
    }
}
