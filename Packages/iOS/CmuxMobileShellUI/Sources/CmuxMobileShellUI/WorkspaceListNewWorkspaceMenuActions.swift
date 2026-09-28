struct WorkspaceListNewWorkspaceMenuActions {
    let createWorkspace: () -> Void
    let createWorkspaceGroup: (() -> Void)?
    var createWorkspaceOnCloudMachine: ((String) -> Void)? = nil
}
