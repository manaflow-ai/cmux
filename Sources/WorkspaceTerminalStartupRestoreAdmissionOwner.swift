/// The topology boundary responsible for releasing restored terminal runtimes.
enum WorkspaceTerminalStartupRestoreAdmissionOwner: Equatable {
    /// Release after a workspace finishes rebuilding or inserting its panels.
    case workspaceTopology

    /// Release only after the owning tab manager publishes the workspace.
    case tabManagerTopology
}
