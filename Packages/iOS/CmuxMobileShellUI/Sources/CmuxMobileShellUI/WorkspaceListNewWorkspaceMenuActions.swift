struct WorkspaceListNewWorkspaceMenuActions {
    let createWorkspace: () -> Void
    let createWorkspaceGroup: (() -> Void)?
    var createWorkspaceOnComputer: ((WorkspaceListNewWorkspaceMenuValue.ComputerTarget) -> Void)? = nil

    func performPrimaryAction(for value: WorkspaceListNewWorkspaceMenuValue) {
        guard value.isEnabled else { return }
        if let target = value.singleConnectedTarget,
           let createWorkspaceOnComputer {
            createWorkspaceOnComputer(target)
        } else {
            createWorkspace()
        }
    }
}
