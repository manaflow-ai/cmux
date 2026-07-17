/// Context-menu lifecycle callbacks forwarded into one hosted sidebar row.
struct SidebarWorkspaceTableContextMenuActions {
    let didOpen: () -> Void
    let didClose: () -> Void
}
