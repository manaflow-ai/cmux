/// The workspaces whose tabs are listed inside the workspace itself (vertical tabs, Leo 2026-10-20): the
/// list beside the workspace's panes owns those tabs, so the sidebar lists none of them under the
/// workspace's row (one list, never two). A workspace's own choice wins over `allWorkspaces`
/// (`tabs.verticalTabs`).
public nonisolated struct SidebarInWorkspaceTabs: Hashable, Sendable {
    public var allWorkspaces: Bool
    public var choices: [WorkspaceID: Bool]

    public init(allWorkspaces: Bool = false, choices: [WorkspaceID: Bool] = [:]) {
        self.allWorkspaces = allWorkspaces
        self.choices = choices
    }

    /// Workspace `id` lists its tabs itself.
    public func contains(_ id: WorkspaceID) -> Bool { choices[id] ?? allWorkspaces }
}
