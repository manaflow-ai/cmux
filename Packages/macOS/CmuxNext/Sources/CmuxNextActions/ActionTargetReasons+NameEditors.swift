/// A rename that names no name opens an editor for the person: the sidebar's inline field (which
/// reveals a hidden sidebar and brings its window forward), the tab's field, the screen bar's, or
/// the palette's ask. Each takes the keyboard. A headless run (CLI, socket, MCP without `focus`)
/// never may (OWNERSHIP-PRINCIPLES), so it is refused with `refusal` before the action runs, and
/// `perform` reports it as not run (QA spree F25).
extension ActionTargetReasons {
    /// The rename actions, and whether an empty name opens the editor too (`screen.rename` clears
    /// the name on an empty one).
    static let nameEditors: [(id: ActionID, emptyOpensEditor: Bool)] = [
        ("renameWorkspace", true), ("renameTab", true), ("workspaceGroup.rename", true), ("screen.rename", false),
    ]

    /// Chains the refusal before each rename action's own target reason. Install after every bind.
    public static func refuseHeadlessNameEditors(in registry: ActionRegistry, refusal: @escaping @MainActor () -> String) {
        for (id, emptyOpensEditor) in nameEditors {
            let previous = registry.action(for: id)?.targetUnavailableReason
            set(id, in: registry) { invocation in
                let name = invocation["name"]?.stringValue
                let opensEditor = name == nil || (emptyOpensEditor && name?.isEmpty == true)
                return opensEditor && !invocation.allowsViewChange ? refusal() : previous?(invocation)
            }
        }
    }
}
