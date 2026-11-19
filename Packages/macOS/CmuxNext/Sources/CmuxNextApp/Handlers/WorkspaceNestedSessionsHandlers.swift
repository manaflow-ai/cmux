import CmuxNextActions
import CmuxNextBridge
import CmuxNextSidebar

/// Show Nested Sessions (`workspace.toggleNestedSessions`): the chat row's "Show nested sessions" (Leo) on a
/// workspace row's menu, the palette, the CLI and MCP. It shows or hides the sessions a workspace started,
/// under its row in the session tree (`SidebarSessionTree.toggle`, kept across launches), as the row's
/// chevron does. Checked while they show. While the tree is off or the workspace started no sessions, the
/// menu leaves the row out, the palette row is disabled and a run is refused, each with that reason.
///
/// The sidebar redraws from the tree's observation (`SidebarSessionTree.drawn` in `RenderState`); a run the
/// person started marks their intent (`ActionRouting.installUserIntentObservers`), so the change shows at
/// once, under the pointer too, as the chevron's reload does.
enum WorkspaceNestedSessionsHandlers {
    static let id: ActionID = "workspace.toggleNestedSessions"

    static func bind(into registry: ActionRegistry, context: AppActionContext, tree: SidebarSessionTree = .shared) {
        registry.bindEffect(id, requires: nil) { invocation in
            let workspace = try parent(invocation, context, tree)
            tree.toggle(workspace)
            return .done
        }
        ActionTargetVisibility.gate(id, in: registry) { invocation in refusal(invocation, context, tree)?.message }
        ActionTargetTitles.setState(id, in: registry) { invocation in shows(invocation, context, tree) }
        ActionTargetTitles.setPaletteState(id, in: registry) { shows(ActionInvocation(), context, tree) ?? false }
    }

    /// The targeted workspace (target, `workspace` argument, else the shown one) as a parent in the live tree.
    private static func parent(_ invocation: ActionInvocation, _ context: AppActionContext,
                               _ tree: SidebarSessionTree) throws -> SidebarWorkspaceID {
        if let failure = refusal(invocation, context, tree) { throw failure }
        guard let id = context.scope(invocation).workspace?.id else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        return SidebarWorkspaceID(id)
    }

    /// Why the action cannot run on its target now, or nil when it can.
    private static func refusal(_ invocation: ActionInvocation, _ context: AppActionContext,
                                _ tree: SidebarSessionTree) -> ActionFailure? {
        guard tree.state != nil else { return .invalidTarget(WorkspaceVerbStrings.sessionTreeOff) }
        guard let id = context.scope(invocation).workspace?.id else { return .invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        return tree.isParent(SidebarWorkspaceID(id)) ? nil : .invalidTarget(WorkspaceVerbStrings.noNestedSessions)
    }

    /// Whether the target's nested sessions show (the row is checked); nil when the action does not apply.
    private static func shows(_ invocation: ActionInvocation, _ context: AppActionContext, _ tree: SidebarSessionTree) -> Bool? {
        guard refusal(invocation, context, tree) == nil, let id = context.scope(invocation).workspace?.id else { return nil }
        return !tree.isFolded(SidebarWorkspaceID(id))
    }
}
