import Foundation

/// Arguments of the workspace verbs (WorkspaceActions.xcstrings).
nonisolated extension CatalogArgument {
    /// The machine (cmux-tui session) a new workspace starts on.
    static var machineMachine: ActionArgument {
        ActionArgument(name: "machine", title: String(localized: "argument.machine", defaultValue: "Machine", table: "WorkspaceActions", bundle: .module),
                       kind: .target(.machine))
    }

    /// The workspace another one merges into.
    static var intoWorkspace: ActionArgument {
        ActionArgument(name: "into", title: String(localized: "argument.into", defaultValue: "Into Workspace", table: "WorkspaceActions", bundle: .module),
                       kind: .target(.workspace))
    }
}
