import CmuxMobileShellModel

struct WorkspaceListFilterMenuActions {
    let setReadState: (MobileWorkspaceReadStateFilter) -> Void
    let clearMachines: () -> Void
    let toggleMachine: (String) -> Void
}
