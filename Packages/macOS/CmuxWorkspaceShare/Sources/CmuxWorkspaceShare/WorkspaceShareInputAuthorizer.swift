public import Foundation

/// Revalidates terminal input against current host-owned session state.
public struct WorkspaceShareInputAuthorizer: Sendable {
    /// Creates a stateless input authorizer.
    public init() {}

    /// Returns whether a participant may write to the current terminal pane.
    ///
    /// Every call must use fresh host state. Relay authorization is not trusted.
    ///
    /// - Parameters:
    ///   - role: The participant's current host-known role.
    ///   - workspaceID: Workspace requested by the participant.
    ///   - paneID: Terminal pane requested by the participant.
    ///   - sharedWorkspaceIDs: Workspaces in the current share session.
    ///   - currentTerminalPaneIDs: Terminal panes currently present in the shared workspace.
    /// - Returns: `true` only for an editor targeting a current terminal pane in a shared workspace.
    public func allowsTerminalInput<WorkspaceIDs, PaneIDs>(
        from role: ShareRole,
        workspaceID: UUID,
        paneID: UUID,
        sharedWorkspaceIDs: WorkspaceIDs,
        currentTerminalPaneIDs: PaneIDs
    ) -> Bool
    where WorkspaceIDs: Collection, WorkspaceIDs.Element == UUID,
          PaneIDs: Collection, PaneIDs.Element == UUID {
        role == .editor
            && sharedWorkspaceIDs.contains(workspaceID)
            && currentTerminalPaneIDs.contains(paneID)
    }
}
