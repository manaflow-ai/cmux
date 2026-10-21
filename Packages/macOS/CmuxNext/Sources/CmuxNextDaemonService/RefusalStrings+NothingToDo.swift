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
}
