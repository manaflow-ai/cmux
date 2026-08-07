import CmuxMobileShellModel

struct WorkspaceListFilterMenuActions {
    let setReadState: (MobileWorkspaceReadStateFilter) -> Void
    let clearMachines: () -> Void
    let toggleMachine: (String) -> Void
    /// Persist an All Computers sort-mode choice. `nil` hides the sort section.
    var setSortMode: ((MobileWorkspaceSortMode) -> Void)? = nil
    /// Present the computer-order editor for
    /// ``MobileWorkspaceSortMode/computerPriority``.
    var editComputerOrder: (() -> Void)? = nil
}
