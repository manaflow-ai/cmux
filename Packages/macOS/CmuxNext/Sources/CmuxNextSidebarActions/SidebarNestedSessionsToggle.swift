public import CmuxNextActions
public import CmuxNextSidebar

/// Show Nested Sessions (`workspace.toggleNestedSessions`): the chat row's "Show nested sessions" (Leo) on a
/// workspace row's menu, the palette, the CLI and MCP. It shows or hides the sessions a workspace started,
/// under its row in the session tree (`SidebarSessionTree.toggle`, kept across launches), as the row's
/// chevron does. Checked while they show. While the tree is off or the workspace started no sessions, the
/// menu leaves the row out, the palette row is disabled and a run is refused, each with that reason.
///
/// The sidebar redraws from the tree's observation (`SidebarSessionTree.drawn` in its render state), so the
/// change shows at once, under the pointer too, as the chevron's does.
@MainActor
public struct SidebarNestedSessionsToggle {
    public static let id: ActionID = "workspace.toggleNestedSessions"
    private let workspace: @MainActor (ActionInvocation) -> String?
    private let tree: SidebarSessionTree

    /// - Parameters:
    ///   - workspace: The invocation's workspace id (its target, `workspace` argument, else the shown one); nil with none.
    ///   - tree: The session tree whose folds the action toggles.
    public init(workspace: @escaping @MainActor (ActionInvocation) -> String?, tree: SidebarSessionTree = .shared) {
        self.workspace = workspace
        self.tree = tree
    }

    public func bind(into registry: ActionRegistry) {
        let toggle = self
        registry.bindEffect(Self.id, unavailable: { nil }) { invocation in
            if let reason = toggle.refusal(invocation) { return .refused(reason) }
            guard let id = toggle.workspace(invocation) else { return .refused(ArchiveStrings.nestedSessionsNoWorkspace) }
            toggle.tree.toggle(WorkspaceID(id))
            return .done
        }
        ActionTargetVisibility.gate(Self.id, in: registry) { toggle.refusal($0) }
        ActionTargetTitles.setState(Self.id, in: registry) { toggle.shows($0) }
        ActionTargetTitles.setPaletteState(Self.id, in: registry) { toggle.shows(ActionInvocation()) ?? false }
    }

    /// Why the action cannot run on its target now, or nil when it can.
    private func refusal(_ invocation: ActionInvocation) -> String? {
        guard tree.state != nil else { return ArchiveStrings.sessionTreeOff }
        guard let id = workspace(invocation) else { return ArchiveStrings.nestedSessionsNoWorkspace }
        return tree.isParent(WorkspaceID(id)) ? nil : ArchiveStrings.noNestedSessions
    }

    /// Whether the target's nested sessions show (the row is checked); nil when the action does not apply.
    private func shows(_ invocation: ActionInvocation) -> Bool? {
        guard refusal(invocation) == nil, let id = workspace(invocation) else { return nil }
        return !tree.isFolded(WorkspaceID(id))
    }
}
