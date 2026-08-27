/// The topology boundary responsible for committing staged terminal restores.
enum WorkspaceTerminalStartupRestoreCommitOwner: Equatable {
    /// Commit after a workspace finishes rebuilding or inserting its panels.
    case workspaceTopology

    /// Commit only after the owning tab manager publishes the workspace.
    case tabManagerTopology
}
