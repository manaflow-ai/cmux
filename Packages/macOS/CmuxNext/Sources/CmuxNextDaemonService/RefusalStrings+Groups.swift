import Foundation

// Tab group, closed-tab, terminal, workspace, and settings refusals.
nonisolated extension RefusalStrings {
    public static func noOpenTabGroup(_ id: String) -> String { text("handlers.refusal.tabGroupGone", "That tab group is no longer open.") }
    public static var tabNotInGroup: String { text("handlers.refusal.tabNotInGroup", "the tab is not in a group") }
    public static var pinnedCannotGroup: String { text("handlers.refusal.pinnedCannotGroup", "pinned tabs cannot be grouped") }
    public static var tabsInDifferentPanes: String { text("handlers.refusal.tabsInDifferentPanes", "the tabs are in different panes") }
    public static var groupArgumentRequired: String { text("handlers.refusal.groupArgumentRequired", "a group argument is required") }
    public static var nameArgumentRequired: String { text("handlers.refusal.nameArgumentRequired", "a name argument is required") }
    public static var colorArgumentRequired: String { text("handlers.refusal.colorArgumentRequired", "a color argument (grey, blue, ...) is required") }
    public static var groupNotSaved: String { text("handlers.refusal.groupNotSaved", "the group is not saved") }
    public static var savedGroupAlreadyOpen: String { text("handlers.refusal.savedGroupAlreadyOpen", "the saved group is already open") }
    public static func noSavedTabGroup(_ id: String) -> String { text("handlers.refusal.savedTabGroupGone", "That saved tab group no longer exists.") }
    public static func workspaceHasNoPane(_ id: String) -> String { text("handlers.refusal.workspaceEmpty", "That workspace has no panes.") }
    public static var otherMachine: String { text("handlers.refusal.groupOtherMachine", "the group and the target are on different machines") }
    public static var groupAtEdge: String { text("handlers.refusal.groupAtEdge", "the group is already at the edge") }
    static var closedTabPaneGone: String { text("handlers.refusal.closedTabPaneGone", "the closed tab's pane is gone and no pane is focused") }
    static var browserReopenNeedsWindow: String { text("handlers.refusal.browserReopenNeedsWindow", "browser tabs reopen only in a pane shown in a window") }
    public static var browserFindClosesWithEscape: String { text("handlers.refusal.browserFindClosesWithEscape", "the browser find bar closes with Escape") }
    public static var nothingSelected: String { text("handlers.refusal.nothingSelected", "nothing is selected") }
    public static var noActiveFind: String { text("handlers.refusal.noActiveFind", "no find is active; use Find first") }
    public static var textArgumentRequired: String { text("handlers.refusal.textArgumentRequired", "a text argument is required") }
    public static var noScreenshot: String { text("handlers.refusal.noScreenshot", "no screenshot found in the screenshot folder") }
    public static var noWorkingDirectory: String { text("handlers.refusal.noWorkingDirectory", "the tab has no known working directory") }
    public static func ghosttyRejected(_ binding: String) -> String { format("handlers.refusal.ghosttyRejected", "Ghostty rejected %@", binding) }
    public static func colorMustBeOneOf(_ choices: String) -> String { format("handlers.refusal.colorMustBeOneOf", "color must be one of %@", choices) }
    public static func statusMustBeOneOf(_ choices: String) -> String { format("handlers.refusal.statusMustBeOneOf", "status must be one of %@", choices) }
    public static var resourceCardNotShown: String {
        text("handlers.refusal.resourceCardNotShown", "the tab or workspace is not shown in a window, so its resource card cannot open")
    }
    public static var workspaceHasNoDirectory: String { text("handlers.refusal.workspaceHasNoDirectory", "the workspace has no working directory") }
    public static var sectionTakesNoWorkspaces: String { text("handlers.refusal.sectionTakesNoWorkspaces", "that section cannot hold workspaces") }
    public static var groupCannotJoinSection: String { text("handlers.refusal.groupCannotJoinSection", "the group's workspaces cannot be added to a section yet") }
    public static var groupAlreadyInSection: String { text("handlers.refusal.groupAlreadyInSection", "every workspace in the group is already in that section") }
    public static var workspaceNotInSidebar: String { text("handlers.refusal.workspaceNotInSidebar", "the workspace is not in the sidebar") }
    public static var noWorkspaceToActOn: String { text("handlers.refusal.noWorkspaceToActOn", "no workspace to act on") }
    /// `id` is for call sites and logs only, never shown.
    public static func noWorkspaceGroup(_ id: String) -> String { text("handlers.refusal.workspaceGroupGone", "That workspace group no longer exists.") }
    public static var workspaceNotInGroup: String { text("handlers.refusal.workspaceNotInGroup", "the workspace is not in a group") }
    public static func noWindow(_ id: String) -> String { text("handlers.refusal.windowGone", "That window is no longer open.") }
    public static func couldNotOpen(_ url: String) -> String { format("handlers.refusal.couldNotOpen", "could not open %@", url) }
    public static var settingsNotLoaded: String { text("handlers.refusal.settingsNotLoaded", "cmux-next.json is not loaded yet") }
    public static var debugSettingsUnavailable: String {
        text("handlers.refusal.debugSettingsUnavailable", "Debug Settings exist only in DEV and NIGHTLY builds")
    }
    public static func noSuchSettingsEntry(_ key: String) -> String {
        format("handlers.refusal.noSuchSettingsEntry", "no setting %@ in Settings", key)
    }
    public static var settingArgumentRequired: String { text("handlers.refusal.settingArgumentRequired", "setting is required (a dotted cmux-next.json path)") }
    public static func settingManaged(_ key: String) -> String {
        format("handlers.refusal.settingManaged", "%@ is managed by your organization", key)
    }

    public static func settingNotToggle(_ key: String) -> String {
        format("handlers.refusal.settingNotToggle", "%@ is not an on/off setting; change it in Settings", key)
    }
    public static var groupRequired: String { text("handlers.refusal.groupRequired", "group is required") }
    public static var groupOnAnotherMachine: String {
        text("handlers.refusal.groupOnAnotherMachine", "a group holds workspaces of one machine; this workspace is on another machine")
    }
}
