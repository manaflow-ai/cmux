// Actions the `cmux` CLI offers by name (ActionDescriptor.cli): each has a
// purpose outside the GUI (plans/cmux-next/state-ownership.md 5). Creating,
// closing, renaming, moving and pinning workspaces, tabs, panes, screens and
// windows; opening and navigating pages; settings that make sense headless;
// agent and Cloud work a script would start. Focus moves, palette and
// sidebar navigation, zoom and GUI-only toggles stay out: `cmux action run
// <id>` still reaches them.

nonisolated extension ActionCatalog {
    static let cliActionIDs: Set<ActionID> = [
        // Windows
        "newWindow", "newIncognitoWindow", "closeWindow", "tab.focus",
        // Workspaces
        "newTab", "newBrowserWorkspace", "openFolder", "reopenClosedWorkspace", "renameWorkspace",
        "palette.clearWorkspaceName", "editWorkspaceDescription", "palette.clearWorkspaceDescription", "closeWorkspace",
        "palette.closeOtherWorkspaces", "palette.toggleWorkspacePin", "palette.markWorkspaceRead", "palette.markWorkspaceUnread",
        "palette.workspaceColor", "palette.resetWorkspaceColor", "moveWorkspaceUp", "moveWorkspaceDown",
        "palette.moveWorkspaceToTop", "moveWorkspaceToWindow", "moveWorkspaceToNewWindow", "clearWorkspaceNotifications",
        "workspace.newAbove", "workspace.newBelow", "workspace.newAtTop", "workspace.newAtBottom", "workspace.newInGroup",
        "workspace.newInNewGroup", "workspace.newOnMachine", "workspace.newInSameDirectory", "workspace.duplicate",
        "workspace.duplicateTerminalsOnly", "workspace.setIcon", "workspace.clearIcon", "workspace.moveToBottom",
        "workspace.moveToNewGroup", "workspace.closeOthersInGroup", "workspace.sortByName", "workspace.sortByLastUsed",
        "workspace.sortByDirectory", "workspace.mergeInto", "workspace.moveToRoom", "workspace.duplicateToRoom",
        // Workspace groups
        "newWorkspaceGroup", "moveWorkspaceToGroup", "removeWorkspaceFromGroup", "workspaceGroup.setColor",
        "workspaceGroup.collapse", "workspaceGroup.expand", "workspaceGroup.moveUp", "workspaceGroup.moveDown",
        "workspaceGroup.moveToWindow", "workspaceGroup.closeWorkspaces", "workspaceGroup.moveToNewWindow",
        "workspaceGroup.newWorkspace", "workspaceGroup.rename", "workspaceGroup.togglePin", "workspaceGroup.markRead",
        "workspaceGroup.markUnread", "workspaceGroup.clearNotifications", "workspaceGroup.ungroup", "workspaceGroup.delete",
        "workspaceGroup.moveToRoom",
        // Rooms
        "room.new", "room.newWindow", "room.newWorkspace", "room.rename", "room.setColor", "room.clearColor", "room.setIcon",
        "room.clearIcon", "room.delete", "room.move", "room.switch",
        // Screens
        "screen.new", "screen.newWith", "screen.duplicate", "screen.close", "screen.closeOthers",
        // Panes
        "splitRight", "splitDown", "newColumn", "pane.moveToNewWorkspace", "equalizeSplits",
        // Tabs
        "newSurface", "openBrowser", "openBrowser.webkit", "openBrowser.chromium", "closeTab", "closeOtherTabsInPane",
        "closeTabsToLeft", "closeTabsToRight", "renameTab", "palette.clearTabName", "moveSurfaceLeft", "moveSurfaceRight",
        "moveSurfaceToPreviousPane", "moveSurfaceToNextPane", "moveSurfaceToPaneLeft", "moveSurfaceToPaneRight",
        "moveSurfaceToPaneUp", "moveSurfaceToPaneDown", "palette.moveTabToNewWorkspace", "palette.toggleTabPin",
        "palette.toggleTabUnread", "duplicateTab", "reloadTab", "reopenClosedBrowserPanel", "hibernateTab", "wakeTab",
        // Tab groups
        "tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab", "tabGroup.rename", "tabGroup.setColor",
        "tabGroup.collapse", "tabGroup.expand", "tabGroup.ungroup", "tabGroup.close", "tabGroup.moveToNewSplit",
        "tabGroup.moveToNewColumn", "tabGroup.moveToNewWorkspace", "tabGroup.moveToWorkspace", "tabGroup.moveToNewWindow",
        "tabGroup.newTab", "tabGroup.save", "tabGroup.unsave", "tabGroup.deleteSaved", "tabGroup.reopenSaved",
        // Browser
        "browserBack", "browserForward", "browserReload", "browserHardReload", "splitBrowserRight", "splitBrowserDown",
        "browserScreenshotPage", "palette.browserClearHistory", "browserNewProfile", "browserRenameProfile",
        "browser.pageInfo.deleteSiteData", "browser.pageInfo.setPermission",
        // Terminals
        "terminal.keep", "resetTerminal", "reconnectPane", "resumeCommandSet", "resumeCommandClear",
        // Notifications
        "markAllNotificationsRead", "clearAllNotifications", "notifications.toggleWorkspaceMute",
        // Agents
        "palette.newAgentChat", "palette.launchClaudeTeams", "palette.launchCodexTeams", "palette.forkAgentConversationNewTab",
        "palette.forkAgentConversationNewWorkspace", "computerUseStop",
        // Cloud and remote machines
        "newCloudWorkspace", "newCloudMachine", "palette.cloud.fork", "palette.cloud.snapshot", "palette.cloud.restore",
        "palette.cloud.promoteTemplate", "palette.cloud.status", "palette.cloud.ports", "palette.cloud.handoff",
        "cloudNewTerminal", "cloudRenameMachine", "cloudKillMachine", "cloudResizeMachine", "cloudDiagnostics",
        "palette.auth.signIn", "palette.auth.signOut", "remote.connect", "remote.newWorkspace", "remote.reconnect",
        "remote.disconnect", "remote.install", "remote.forget",
        // Settings that make sense headless
        "reloadConfiguration", "palette.toggleSetting", "palette.shortcutKeymap", "palette.installCLI", "palette.uninstallCLI",
        "palette.restartSocketListener", "palette.checkForUpdates", "palette.applyUpdateIfAvailable", "palette.switchAppChannel",
        "appearance.density.compact", "appearance.density.comfortable", "appearance.animationSpeed.fast",
        "appearance.animationSpeed.normal", "appearance.animationSpeed.off", "browser.defaultEngine.chromium",
        "browser.defaultEngine.webkit", "appearance.titlebar.minimal", "appearance.titlebar.standard",
    ]
}
