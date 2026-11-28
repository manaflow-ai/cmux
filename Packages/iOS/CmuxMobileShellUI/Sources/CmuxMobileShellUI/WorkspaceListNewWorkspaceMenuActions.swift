import CmuxMobileShell

struct WorkspaceListNewWorkspaceMenuActions {
    let createWorkspace: () -> Void
    let createWorkspaceGroup: (() -> Void)?
    /// Creates a workspace on the chosen computer (see
    /// ``WorkspaceListNewWorkspaceMenuValue/computerTargets``); the kind is
    /// set for SSH computers and `nil` for Macs or Cloud machines.
    var createWorkspaceOnComputer: ((WorkspaceCreateComputerTarget, MobileSSHWorkspaceKind?) -> Void)? = nil
    /// Creates a workspace of a kind on the one SSH computer `+` targets.
    var createSSHWorkspace: ((MobileSSHWorkspaceKind) -> Void)? = nil

    func performPrimaryAction(for value: WorkspaceListNewWorkspaceMenuValue) {
        guard value.isEnabled else { return }
        if let target = value.singleConnectedTarget,
           let createWorkspaceOnComputer {
            createWorkspaceOnComputer(target, nil)
        } else {
            createWorkspace()
        }
    }
}
