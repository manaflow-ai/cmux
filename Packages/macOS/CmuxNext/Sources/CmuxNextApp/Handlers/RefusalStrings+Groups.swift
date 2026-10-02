import Foundation

// Tab group, closed-tab, terminal, workspace, and settings refusals.
nonisolated extension RefusalStrings {
    static func noOpenTabGroup(_ id: String) -> String { format("handlers.refusal.noOpenTabGroup", "no open tab group %@", id) }
    static var tabNotInGroup: String { text("handlers.refusal.tabNotInGroup", "the tab is not in a group") }
    static var pinnedCannotGroup: String { text("handlers.refusal.pinnedCannotGroup", "pinned tabs cannot be grouped") }
    static var groupArgumentRequired: String { text("handlers.refusal.groupArgumentRequired", "a group argument is required") }
    static var nameArgumentRequired: String { text("handlers.refusal.nameArgumentRequired", "a name argument is required") }
    static var colorArgumentRequired: String { text("handlers.refusal.colorArgumentRequired", "a color argument (grey, blue, ...) is required") }
    static var groupNotSaved: String { text("handlers.refusal.groupNotSaved", "the group is not saved") }
    static var savedGroupAlreadyOpen: String { text("handlers.refusal.savedGroupAlreadyOpen", "the saved group is already open") }
    static func noSavedTabGroup(_ id: String) -> String { format("handlers.refusal.noSavedTabGroup", "no saved tab group %@", id) }
    static func workspaceHasNoPane(_ id: String) -> String { format("handlers.refusal.workspaceHasNoPane", "workspace %@ has no pane", id) }
    static var otherMachine: String { text("handlers.refusal.groupOtherMachine", "the group and the target are on different machines") }
    static var groupAtEdge: String { text("handlers.refusal.groupAtEdge", "the group is already at the edge") }
    static var closedTabPaneGone: String { text("handlers.refusal.closedTabPaneGone", "the closed tab's pane is gone and no pane is focused") }
    static var browserReopenNeedsWindow: String { text("handlers.refusal.browserReopenNeedsWindow", "browser tabs reopen only in a pane shown in a window") }
    static var browserFindClosesWithEscape: String { text("handlers.refusal.browserFindClosesWithEscape", "the browser find bar closes with Escape") }
    static var nothingSelected: String { text("handlers.refusal.nothingSelected", "nothing is selected") }
    static var noActiveFind: String { text("handlers.refusal.noActiveFind", "no find is active; use Find first") }
    static var textArgumentRequired: String { text("handlers.refusal.textArgumentRequired", "a text argument is required") }
    static var noScreenshot: String { text("handlers.refusal.noScreenshot", "no screenshot found in the screenshot folder") }
    static var noWorkingDirectory: String { text("handlers.refusal.noWorkingDirectory", "the tab has no known working directory") }
    static func ghosttyRejected(_ binding: String) -> String { format("handlers.refusal.ghosttyRejected", "Ghostty rejected %@", binding) }
    static var textBoxUnported: String { text("handlers.refusal.textBoxUnported", "needs the TextBox composer, which cmux-next does not have yet") }
    static func colorMustBeOneOf(_ choices: String) -> String { format("handlers.refusal.colorMustBeOneOf", "color must be one of %@", choices) }
    static var resourceCardNotShown: String {
        text("handlers.refusal.resourceCardNotShown", "the tab or workspace is not shown in a window, so its resource card cannot open")
    }
    static var workspaceHasNoDirectory: String { text("handlers.refusal.workspaceHasNoDirectory", "the workspace has no working directory") }
    static var workspaceNotInSidebar: String { text("handlers.refusal.workspaceNotInSidebar", "the workspace is not in the sidebar") }
    static var noWorkspaceToActOn: String { text("handlers.refusal.noWorkspaceToActOn", "no workspace to act on") }
    static func noWorkspaceGroup(_ id: String) -> String { format("handlers.refusal.noWorkspaceGroup", "no workspace group %@", id) }
    static var workspaceNotInGroup: String { text("handlers.refusal.workspaceNotInGroup", "the workspace is not in a group") }
    static func noWindow(_ id: String) -> String { format("handlers.refusal.noWindow", "no window %@", id) }
    static func couldNotOpen(_ url: String) -> String { format("handlers.refusal.couldNotOpen", "could not open %@", url) }
    static var settingsNotLoaded: String { text("handlers.refusal.settingsNotLoaded", "cmux.json is not loaded yet") }
    static var debugSettingsUnavailable: String {
        text("handlers.refusal.debugSettingsUnavailable", "Debug Settings exist only in DEV and NIGHTLY builds")
    }
    static var settingArgumentRequired: String { text("handlers.refusal.settingArgumentRequired", "setting is required (a dotted cmux.json path)") }
    static func settingManaged(_ key: String) -> String {
        format("handlers.refusal.settingManaged", "%@ is managed by your organization", key)
    }

    static func settingNotToggle(_ key: String) -> String {
        format("handlers.refusal.settingNotToggle", "%@ is not an on/off setting; change it in Settings", key)
    }
    static var groupRequired: String { text("handlers.refusal.groupRequired", "group is required") }
}
