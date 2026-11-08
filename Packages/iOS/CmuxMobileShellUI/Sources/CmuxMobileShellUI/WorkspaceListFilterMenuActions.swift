import CmuxMobileShellModel

struct WorkspaceListFilterMenuActions {
    let setReadState: (MobileWorkspaceReadStateFilter) -> Void
    let clearMachines: () -> Void
    let toggleMachine: (String) -> Void
    /// Persist an All Computers sort-mode choice. `nil` hides the sort tiles.
    var setSortMode: ((MobileWorkspaceSortMode) -> Void)? = nil
}
