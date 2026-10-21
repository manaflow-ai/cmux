import AppKit

// The rows nested under agent chat tabs (their sub-sessions, `SidebarSubsessionRow`).
extension SidebarListViewComponents {
    /// A press (or AXPress) on tab row `tab` of `workspace`. A nested sub-session header opens or
    /// closes its list: the window's view state, kept here, so nothing reaches the daemon. Any
    /// other tab row, a sub-session's included, goes to the sidebar's tab selection; the App opens
    /// a sub-session's chat beside its parent's tab there.
    func activateTabRow(_ workspace: WorkspaceID, _ tab: TabID) {
        guard let nested = SidebarSubsessionRowID(tab), nested.session == nil else {
            return model.send(.selectTab(workspace: workspace, tab: tab))
        }
        let parent = nested.parentTab
        let open = tabs[parent].map { SidebarSubsessionRow.isExpanded($0, overrides: subsessionExpansion) }
            ?? subsessionExpansion[parent] ?? false
        subsessionExpansion[parent] = !open
        reload(animated: true)
    }
}
