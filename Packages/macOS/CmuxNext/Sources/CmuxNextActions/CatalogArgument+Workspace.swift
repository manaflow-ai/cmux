import Foundation

/// Arguments of the workspace verbs (WorkspaceActions.xcstrings).
nonisolated extension CatalogArgument {
    /// The machine (cmux-tui session) a new workspace starts on.
    static var machineMachine: ActionArgument {
        ActionArgument(name: "machine", title: String(localized: "argument.machine", defaultValue: "Machine", table: "WorkspaceActions", bundle: .module),
                       kind: .target(.machine))
    }

    /// The machine an action moves work to; without one the action picks or starts one.
    static var optionalMachine: ActionArgument {
        ActionArgument(name: "machine", title: String(localized: "argument.machine", defaultValue: "Machine", table: "WorkspaceActions", bundle: .module),
                       kind: .target(.machine), isRequired: false)
    }


    /// A connected peer or Cloud machine where a new agent chat starts.
    static var agentHostMachine: ActionArgument {
        ActionArgument(name: "host", title: String(localized: "argument.agent.host", defaultValue: "Session Host", bundle: .module),
                       kind: .target(.machine))
    }

    /// The workspace another one merges into.
    static var intoWorkspace: ActionArgument {
        ActionArgument(name: "into", title: String(localized: "argument.into", defaultValue: "Into Workspace", table: "WorkspaceActions", bundle: .module),
                       kind: .target(.workspace))
    }

    /// The workspace another one moves right before or after (Move Workspace Above or Below).
    static var anchorWorkspace: ActionArgument {
        ActionArgument(name: "anchor", title: String(localized: "argument.anchor", defaultValue: "Next to Workspace", table: "WorkspaceActions", bundle: .module),
                       kind: .target(.workspace))
    }
}
