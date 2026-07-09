internal import Foundation

/// The residual v1 line-protocol dispatch for the workspace commands
/// (`list_workspaces`, `new_workspace`, `new_split`, `close_workspace`,
/// `select_workspace`, `current_workspace`) — the byte-faithful twins of the
/// former `TerminalController` v1 cases.
///
/// These commands have no exact v2 counterpart this coordinator could reshape:
/// the v1 commands take positional `<id|idx|direction>` arguments and return
/// flat reply lines, while the `workspace.*` methods take JSON params and return
/// JSON. They also differ behaviorally from their v2 cousins — they read the
/// controller's active `TabManager` directly (erroring when it is absent rather
/// than falling back to the scriptable window), `select_workspace` selects in
/// place (no cross-window focus / `setActiveTabManager`) and accepts an index,
/// and `new_split` has no `workspace.*` equivalent at all. So the irreducibly
/// app-coupled bodies stay app-resident behind the ``ControlWorkspaceContext``
/// `*V1` witnesses and each case forwards the raw `args` and returns the
/// witness's raw reply verbatim — the ``handleSurfaceSendNotifyV1`` shape.
extension ControlCommandCoordinator {
    /// Dispatches the v1 workspace commands this coordinator owns; returns `nil`
    /// for anything else so the app's legacy v1 dispatcher can fall through.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    /// - Returns: The raw reply line, or `nil` if not owned here.
    public func handleWorkspaceV1(command: String, args: String) -> String? {
        switch command {
        case "list_workspaces":
            return workspaceContext?.controlListWorkspacesV1()
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "new_workspace":
            return workspaceContext?.controlNewWorkspaceV1(args: args)
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "new_split":
            return workspaceContext?.controlNewSplitV1(args: args)
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "close_workspace":
            return workspaceContext?.controlCloseWorkspaceV1(arg: args)
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "select_workspace":
            return workspaceContext?.controlSelectWorkspaceV1(arg: args)
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "current_workspace":
            return workspaceContext?.controlCurrentWorkspaceV1()
                ?? Self.windowWorkspaceContextUnavailableResponse
        default:
            return nil
        }
    }

    /// The workspace-domain slice of the seam (a typed view of ``context``).
    var workspaceContext: (any ControlWorkspaceContext)? {
        context
    }
}
