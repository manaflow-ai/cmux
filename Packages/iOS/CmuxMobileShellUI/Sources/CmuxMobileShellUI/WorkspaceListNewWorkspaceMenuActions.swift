struct WorkspaceListNewWorkspaceMenuActions {
    let createWorkspace: () -> Void
    let createWorkspaceGroup: (() -> Void)?
    /// Creates a workspace on the chosen computer (see
    /// ``WorkspaceListNewWorkspaceMenuValue/computerTargets``).
    var createWorkspaceOnComputer: ((WorkspaceCreateComputerTarget) -> Void)? = nil
}
