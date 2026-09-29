struct WorkspaceListNewWorkspaceMenuActions {
    let createWorkspace: () -> Void
    let createWorkspaceGroup: (() -> Void)?
    var createWorkspaceOnComputer: ((WorkspaceListNewWorkspaceMenuValue.ComputerTarget) -> Void)? = nil
}
