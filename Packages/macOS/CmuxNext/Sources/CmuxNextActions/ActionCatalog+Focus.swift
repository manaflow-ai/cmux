// Actions whose purpose is a view change (ActionDescriptor.focuses): moving
// focus between panes or tabs, selecting a tab, showing a workspace, going
// back in the focus history, opening what a notification points at, and
// bringing a window forward. A run of one of these may change this client's
// view from any origin (plans/cmux-next/OWNERSHIP-PRINCIPLES.md); every
// other action changes it only for the user or with `focus: true`.

nonisolated extension ActionCatalog {
    static let focusActionIDs: Set<ActionID> = [
        // Tabs
        "tab.focus", "nextSurface", "prevSurface", "selectSurfaceByNumber", "tab.search",
        // Panes and focus targets
        "focusLeft", "focusRight", "focusUp", "focusDown", "focusPreviousPane", "focusNextPane",
        "column.focusLeft", "column.focusRight", "canvasRevealFocusedPane", "focusBrowserAddressBar", "focusTextBoxInput", "focusRightSidebar",
        // Screens
        "screen.next", "screen.previous", "screen.select", "screen.selectLast",
        // Workspaces and rooms
        "nextSidebarTab", "prevSidebarTab", "nextSidebarTabInGroup", "prevSidebarTabInGroup", "nextWorkspaceGroup", "prevWorkspaceGroup", "selectWorkspaceByNumber",
        "goToWorkspace", "workspace.selectFirst", "workspace.selectLast", "workspace.selectLastUsed",
        "space.next", "space.previous", "space.selectByNumber", "space.switch", "home.show", "home.openConversation",
        // Focus history and notifications
        "focusHistoryBack", "focusHistoryForward", "focusHistoryLast", "jumpToUnread", "markOldestUnreadAndJumpNext",
        "notificationOpen", "vaultFocusSession", "computerUseFocus", "computerUseFocusCallingTerminal",
        // Windows
        "showMainWindow", "showHideAllWindows",
    ]
}
