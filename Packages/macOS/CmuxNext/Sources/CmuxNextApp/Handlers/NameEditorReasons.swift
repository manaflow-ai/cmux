import CmuxNextActions

/// A rename that names no name opens an editor for the person: the sidebar's inline field (which
/// reveals a hidden sidebar and brings its window forward), the tab's field, the screen bar's, or
/// the palette's ask. Each takes the keyboard. A headless run (CLI, socket, MCP without `focus`)
/// never may (OWNERSHIP-PRINCIPLES), so it is refused with "a name argument is required" before
/// the action runs, and `perform` reports it as not run (QA spree F25).
@MainActor
enum NameEditorReasons {
    /// The rename actions, and whether an empty name opens the editor too (`screen.rename` clears
    /// the name on an empty one).
    static let actions: [(id: ActionID, emptyOpensEditor: Bool)] = [
        ("renameWorkspace", true), ("renameTab", true), ("workspaceGroup.rename", true), ("screen.rename", false),
    ]

    /// Chains the refusal before each action's own target reason. Install after every bind.
    static func install(_ services: AppServices) {
        let registry = services.registry
        for (id, emptyOpensEditor) in actions {
            let previous = registry.action(for: id)?.targetUnavailableReason
            ActionTargetReasons.set(id, in: registry) { invocation in
                if opensEditor(invocation, emptyOpensEditor: emptyOpensEditor), !invocation.allowsViewChange {
                    return RefusalStrings.nameArgumentRequired
                }
                return previous?(invocation)
            }
        }
    }

    static func opensEditor(_ invocation: ActionInvocation, emptyOpensEditor: Bool) -> Bool {
        guard let name = invocation["name"]?.stringValue else { return true }
        return emptyOpensEditor && name.isEmpty
    }
}
