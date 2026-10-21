import Foundation

/// Reasons for an action that has nothing to act on in the current state (no tab to the right,
/// an app pane without a tab bar): the menu row is disabled with the reason and every other run
/// is refused with it, instead of reporting success after doing nothing.
nonisolated extension RefusalStrings {
    /// Show Tab Bar or New Horizontal Tab on an app workspace's pane.
    public static var appPaneHasNoTabBar: String { text("handlers.refusal.noTabBar.appPane", "An app's pane has no tab bar.") }
    /// Show Tab Bar or New Horizontal Tab on the Home Chief pane.
    public static var chiefPaneHasNoTabBar: String { text("handlers.refusal.noTabBar.chiefPane", "The Home Chief pane has no tab bar.") }
    /// Duplicate Tab on a page tab (one tab per page per window).
    public static var pageTabOpensOnce: String {
        text("handlers.refusal.duplicate.pageOpensOnce", "A page opens once per window, so its tab can't be duplicated.")
    }
    /// Close Other Tabs with no other unpinned tab.
    public static var noOtherTabsToClose: String {
        text("handlers.refusal.closeTabs.noOthers", "There are no other tabs to close. Pinned tabs stay open.")
    }
    /// Close Tabs to the Right on the last unpinned tab.
    public static var noTabsToTheRight: String { text("handlers.refusal.closeTabs.noneToRight", "There are no tabs to the right to close.") }
    /// Close Tabs to the Left on the first unpinned tab.
    public static var noTabsToTheLeft: String { text("handlers.refusal.closeTabs.noneToLeft", "There are no tabs to the left to close.") }
    /// Close Other Workspaces with no other row that closes (Home never closes).
    public static var noOtherWorkspacesToClose: String { text("handlers.refusal.closeWorkspaces.noOthers", "There are no other workspaces to close.") }
    /// Close Workspaces Below on the bottom row.
    public static var noWorkspacesBelowToClose: String { text("handlers.refusal.closeWorkspaces.noneBelow", "There are no workspaces below to close.") }
    /// Close Workspaces Above on the top row.
    public static var noWorkspacesAboveToClose: String { text("handlers.refusal.closeWorkspaces.noneAbove", "There are no workspaces above to close.") }
    /// Close Other Workspaces in Group on a group's only workspace.
    public static var noOtherWorkspacesInGroupToClose: String {
        text("handlers.refusal.closeWorkspaces.noOthersInGroup", "There are no other workspaces in this group to close.")
    }
    /// Next or Previous Workspace in Group alone in its group.
    public static var noOtherWorkspaceInGroup: String { text("handlers.refusal.group.noOtherWorkspace", "This workspace is the only one in its group.") }
    /// Rename Workspace (the name field) on Home, which the sidebar shows as its Home item.
    public static var homeKeepsItsName: String { text("handlers.refusal.rename.homeKeepsName", "Home keeps its name.") }
    /// Move Workspace Group Up or to Top on the section's first row.
    public static var groupAlreadyAtTop: String { text("handlers.refusal.group.atTop", "The group is already at the top.") }
    /// Move Workspace Group Down or to Bottom on the section's last row.
    public static var groupAlreadyAtBottom: String { text("handlers.refusal.group.atBottom", "The group is already at the bottom.") }
    /// Next or Previous Workspace Group in a room with no group.
    public static var noWorkspaceGroups: String { text("handlers.refusal.group.none", "There are no workspace groups.") }
    /// Next or Previous Workspace Group when no group lists a workspace to show.
    public static var noWorkspaceGroupToGoTo: String { text("handlers.refusal.group.noneToGoTo", "No workspace group has a workspace to go to.") }
    /// Edit Group Config on a group whose workspaces have no folder (its entry is found by one).
    public static var groupHasNoFolder: String {
        text("handlers.refusal.group.noFolder", "This group has no folder yet. Its settings are found by the folder of its first workspace.")
    }
}
