public import Foundation

/// Revalidates relay-authorized terminal input against current host layout.
public struct WorkspaceShareInputAuthorizer: Sendable {
    /// Creates a stateless input authorizer.
    public init() {}

    /// Returns whether relay-forwarded input targets the current terminal pane.
    ///
    /// The relay owns participant identity and role authorization before it
    /// creates a forwarded-input frame. Rechecking a lagging participant
    /// snapshot here would drop leading keystrokes immediately after approval.
    /// The host remains authoritative for its current workspace and pane layout.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace requested by the participant.
    ///   - paneID: Terminal pane requested by the participant.
    ///   - sharedWorkspaceIDs: Workspaces in the current share session.
    ///   - currentTerminalPaneIDs: Terminal panes currently present in the shared workspace.
    /// - Returns: `true` only for a current terminal pane in a shared workspace.
    public func allowsForwardedTerminalInput<WorkspaceIDs, PaneIDs>(
        workspaceID: UUID,
        paneID: UUID,
        sharedWorkspaceIDs: WorkspaceIDs,
        currentTerminalPaneIDs: PaneIDs
    ) -> Bool
    where WorkspaceIDs: Collection, WorkspaceIDs.Element == UUID,
          PaneIDs: Collection, PaneIDs.Element == UUID {
        sharedWorkspaceIDs.contains(workspaceID)
            && currentTerminalPaneIDs.contains(paneID)
    }
}
