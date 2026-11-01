// Why no right-click menu offers an action (plans/cmux-next/actions.md);
// the other surfaces' decisions are in ActionSurfaceCatalog+Exemptions.swift.

nonisolated extension ActionSurfaceCatalog {
    /// Why no right-click menu offers an action.
    static let contextMenuExemption: [ActionID: SurfaceExemption] = byReason(contextMenuExemptionsByReason)
    static let contextMenuExemptionsByReason: [SurfaceExemption: [ActionID]] = [
        // The menus offer New Tab Page, whose field is this action's GUI form.
        .duplicateOfDefault: [
            "newTab.submit",
            // A tab's menu offers New Tab to the Right and, in its New submenu, New <Kind> Tab and the kinds; Cmd-T's
            // setting-driven New Tab stays in the File menu and the palette.
            "newTab.default",
            // The tab's menu has New Tab to the Right (this, Chrome's name) and, in New, at Start and at End.
            "newTab.afterCurrent",
            // The pane's menu offers Show Tab Bar (Hide Tab Bar while shown), and the bar's + adds a tab once it shows.
            "newTab.horizontal",
        ],
        .secondaryEngine: [
            "openBrowser.webkit",
            "browser.openInWebKit",
        ],
        .unimplemented: [
            "palette.browserToggleOmnibar",
        ],
        .noObject: [
            "window.toggleDockLeft", "window.toggleDockRight", "window.toggleDockTop", "window.toggleDockBottom",
            "window.toggleDockOrientation",
            "palette.openFilesPane", "palette.openFindPane",
            "sidebar.profileMenu", "browser.downloads.showFolder",
            "home.show",
            "openSettings", "appearance.customize", "newWindow", "newIncognitoWindow", "closeWindow", "minimizeWindow", "toggleFullScreen",
            "closeAllWindows", "window.closeOthers", "window.mergeAll", "workspace.closeAllInAllWindows", "zoomWindow", "selectNextWindow", "selectPreviousWindow",
            "quit", "quitKeepSessions", "quitEndSessions", "quitEndEverything", "globalSearch", "commandPalette",
            "palette.openTaskManager", "palette.sleepyMode", "keepMacAwake", "about", "manageLayouts",
            "palette.findWork", "reopenClosedBrowserPanel", "palette.browserClearHistory", "importFromBrowser", "password.importCSV", "browser.importFromFiles", "browser.allowAgentWithExtensions",
            "workspace.importClassic", "session.moveFromBuild", "fileEditor.importEditorSettings", "palette.enableBrowser", "palette.disableBrowser", "toggleRightSidebar", "switchRightSidebarToFiles",
            "switchRightSidebarToFind", "switchRightSidebarToSessions", "switchRightSidebarToFeed",
            "switchRightSidebarToDock", "switchRightSidebarToMachines", "palette.toggleMatchTerminalBackground",
            "showNotifications", "feed.show", "markAllNotificationsRead",
            "clearAllNotifications", "notifications.toggleBanners", "notifications.dismissal.keystroke",
            "notifications.setAgentSound", "notifications.setEventSound", "notifications.importSound",
            "notifications.dismissal.focus", "notifications.dismissal.click", "notifications.dismissal.explicit",
            "notifications.dismissal.timeout", "notifications.dismissal.never", "palette.openTerminalChatView",
            "palette.quickAgentChat",
            "palette.launchClaudeTeams", "palette.launchCodexTeams", "palette.computerUse.setup",
            "palette.computerUse.accessibility", "palette.computerUse.screenRecording", "palette.computerUse.restart", "computerUseStop",
            "newCloudMachine", "cloudDiagnostics", "openTeamPicker", "palette.auth.signIn", "palette.auth.signOut",
            "palette.mobileConnect", "accounts.show", "accounts.refresh", "accounts.reauthenticate",
            "accounts.connect", "accounts.remove", "reloadConfiguration", "palette.openCmuxSettingsFile",
            "palette.openGhosttySettings", "settings.customizeMenus", "ghostty.showDiagnostics", "palette.makeDefaultBrowser", "palette.makeDefaultTerminal",
            "palette.toggleSetting", "palette.shortcutKeymap", "palette.searchShortcuts", "palette.installCLI",
            "palette.uninstallCLI", "palette.restartSocketListener", "palette.restartServer", "palette.checkForUpdates", "updates.whatsNew", "announcements.show", "announcements.hide",
            "palette.applyUpdateIfAvailable", "palette.switchAppChannel", "updates.rollback", "palette.pro.upgrade",
            "sendFeedback", "help.featureFlags", "help.documentation", "help.showCrashLogs",
            "appearance.density.compact", "appearance.density.comfortable", "appearance.density.ultraCompact", "appearance.density.cozy", "appearance.density.spacious", "appearance.density.set", "appearance.density.create", "appearance.animationSpeed.fast",
            "appearance.animationSpeed.normal", "appearance.animationSpeed.off", "appearance.animations.newTab.toggle", "appearance.animations.newWorkspace.toggle", "appearance.animations.bounce.subtle", "appearance.animations.bounce.none", "appearance.animations.toggle", "appearance.animations.sidebar.toggle", "appearance.animations.tabs.toggle", "appearance.animations.panes.toggle", "appearance.animations.overlays.toggle", "appearance.animations.hoverCards.toggle", "appearance.animations.home.toggle", "appearance.animations.cursor.toggle", "appearance.animations.indicators.toggle", "appearance.animations.feedback.toggle", "appearance.animations.web.toggle",
            "browser.defaultEngine.chromium",
            "browser.defaultEngine.webkit", "appearance.paneBorder.toggle", "appearance.panePadding.toggle",
            "appearance.paneCorners.toggle", "layout.centerFocusedColumn.never", "layout.centerFocusedColumn.always",
            "layout.centerFocusedColumn.onOverflow", "focusRing.toggle", "focusRing.style.ring",
            "focusRing.style.glow", "focusRing.singlePane.toggle", "appearance.paneBorderWidth.toggle",
            "appearance.paneBorderColor.reset", "appearance.titlebar.minimal", "appearance.titlebar.standard",
            "browser.hibernation.off", "browser.hibernation.moderate", "browser.hibernation.aggressive",
            "browser.keepNeighborTabsAwake.0", "browser.keepNeighborTabsAwake.1", "browser.keepNeighborTabsAwake.2",
            "browser.keepNeighborTabsAwake.3",
            "layout.toggleStripScrollbar", "recentlyFocused", "recentlyClosed", "history.commands", "history.show", "agentHistory.show",
            "music.open", "music.stop",
            "browserShowHistory", "history.search", "history.resumeAgentSession", "history.reopen", "history.open", "history.clear",
            "layout.undo", "agentActivity.open",
            "palette.openVaultPane",
        ],
        .noTargetSurface: [
            "browserProfile.openLink", "file.open",
            "tabGroup.deleteSaved",
            "tabGroup.reopenSaved",
            "taskManager.killProcess", "toggleChecklistItemComplete", "canvasOverview", "canvasTidy",
            "canvasAlignLeft", "canvasAlignRight", "canvasAlignTop", "canvasAlignBottom", "canvasEqualizeWidths",
            "canvasEqualizeHeights", "canvasDistributeHorizontally", "canvasDistributeVertically", "simulatorHome",
            "simulatorRotateLeft", "simulatorRotateRight", "simulatorToggleAppearance",
            "simulatorToggleSoftwareKeyboard", "agentPane.searchChats", "screenGroup.reopenSaved", "screenGroup.deleteSaved",
            "resumeCommandSet", "resumeCommandEdit", "resumeCommandClear", "saveFilePreview", "markdownSave",
            "markdownLink", "markdownBack", "markdownForward", "markdownReload", "markdownResetTableWidths", "markdownGoToTop",
            "toggleFileEditorWordWrap", "filePreviewOpenWith", "filePreviewOpenExternally",
            "filePreviewRevealInFinder", "filePreviewRevealInFiles", "diffViewerNextLine", "diffViewerPreviousLine", "diffViewerHalfPageDown",
            "diffViewerHalfPageUp", "diffViewerNextHunk", "diffViewerPreviousHunk", "diffViewerGoToBottom",
            "diffViewerGoToTop", "diffViewerSearch", "diffViewerNextFile", "diffViewerPreviousFile", "fileEditorGotoLine", "fileEditorReplace", "fileEditorAction",
            "palette.vscodeServeWebStop", "palette.vscodeServeWebRestart", "fileExplorerOpenSelection",
            "fileExplorerOpenSelectionFinderAlias", "vaultOpenSession",
            "vaultResumeInNewWorkspace", "vaultCopyResumeCommand", "vaultOpenPullRequest", "checklistEditItem",
            "checklistMarkInProgress", "checklistCompleteItem", "checklistRemoveItem", "checklistOpenAsPane",
            "checklistAttachImages", "cloudExec", "cloudDomainList", "cloudPublicationList", "cloudAPIKeyList", "cloudAPIKeyRevoke", "cloudListMachines",
        ],
        .focusMove: [
            "history.goTo",
            "showHideAllWindows", "goToWorkspace", "search.chats", "showMainWindow", "tab.focus", "pane.focus", "screen.focus", "nextSidebarTab", "prevSidebarTab",
            "nextSidebarTabInGroup", "prevSidebarTabInGroup", "nextWorkspaceGroup", "prevWorkspaceGroup",
            "selectWorkspaceByNumber", "workspace.selectFirst",
            "workspace.selectLast", "workspace.selectLastUsed", "space.next", "space.previous", "space.selectByNumber",
            "space.switch", "focusLeft", "focusRight", "focusUp", "focusDown", "focusPreviousPane", "focusNextPane",
            "focusPaneByNumber", "focusSidebar",
            "canvasRevealFocusedPane", "navigate.next", "navigate.previous", "nextSurface", "prevSurface", "selectSurfaceByNumber",
            "screen.next", "screen.previous", "screen.select", "screen.selectLast", "focusTextBoxInput",
            "focusBrowserAddressBar", "browser.focusSearch", "focusLocation", "focusRightSidebar", "vaultFocusSession", "jumpToUnread", "jumpToLastPrompt",
            "markOldestUnreadAndJumpNext", "computerUseFocus", "computerUseFocusCallingTerminal", "column.focusLeft",
            "column.focusRight", "focusHistoryBack", "focusHistoryForward", "focusHistoryLast",
        ],
        .stepAdjust: [
            "resizePaneLeft", "resizePaneRight", "resizePaneUp", "resizePaneDown", "increaseWorkspaceTerminalFontSize",
            "decreaseWorkspaceTerminalFontSize", "resetWorkspaceTerminalFontSize", "canvasZoomIn", "canvasZoomOut",
            "canvasZoomReset", "browserZoomIn", "browserZoomOut", "browserZoomReset", "markdownZoomIn",
            "markdownZoomOut", "markdownZoomReset", "fileEditorZoomIn", "fileEditorZoomOut", "fileEditorZoomReset", "appearance.uiScale.increase", "appearance.uiScale.decrease", "appearance.uiScale.reset", "column.cycleWidth",
            // The app's Interface Size; the chat's own zoom is the agent chat menu's.
            "appearance.interfaceSize.increase", "appearance.interfaceSize.decrease", "appearance.interfaceSize.reset",
            "column.cycleWidthBack", "terminal.increaseFontSize", "terminal.decreaseFontSize",
            "terminal.resetFontSize", "terminal.scrollPageUp", "terminal.scrollPageDown", "terminal.scrollToTop",
            "terminal.scrollToBottom",
        ],
        .familyMember: [
            "cycleWorkspaceStatus", "workspaceGroup.collapse", "workspaceGroup.expand", "openBrowser",
            "tabGroup.collapse", "tabGroup.expand", "screenGroup.collapse", "screenGroup.expand",
            "browser.extension.run", "browser.extension.options", "browser.extension.pin", "browser.extension.unpin",
            "browser.extension.enable", "browser.extension.disable", "browser.extension.reload",
            "browser.extension.remove", "browser.extension.command", "palette.attemptUpdate",
            // The tab menu's Mute Tab / Unmute Tab is the toggle, titled for the tab.
            "tab.muteAudio", "tab.unmuteAudio",
        ],
        .liveInput: [
            "browserLinkHints", "browserLinkHintsNewSplit", "hints.show",
            "palette.toggleDictation",
            "toggleTerminalCopyMode", "palette.terminalToggleTextBoxInput", "cycleTextBoxSubmitAction",
            "attachTextBoxFile", "sendCtrlFToTerminal", "pasteLastScreenshot", "findInDirectory", "findNext",
            "findPrevious", "hideFind", "toggleUnread", "terminal.scrollToSelection",
        ],
        .dragGesture: [
            "space.move", "browser.extension.move", "bookmark.move", "space.moveLeft", "space.moveRight",
            "space.moveToStart", "space.moveToEnd",
            // A row drag drops next to any row; the row menu offers Move to Top, Up, Down and Bottom (cmux#29907).
            "workspace.moveAbove", "workspace.moveBelow",
        ],
        .minimalMenu: [
            "space.setDefaults", "space.clearDefaults", "browserProfile.clearSpaceDefault",
            // Open in New Window took its row (spaces-overhaul-DESIGN.md rule 4); New Window in Space… (a new
            // window with a new workspace of the space) stays in the palette and the CLI.
            "space.newWindow",
        ],
        // Leo 2026-10-23: the workspace row menu drops this long tail; the palette keeps it.
        .pointerMenuTrim: [
            // Specialist tab controls stay canonical palette/CLI commands, outside the
            // compact pointer menu. Shared commands keep their other menu placements.
            "terminal.keep", "terminal.setTheme", "terminal.clearTheme", "palette.toggleTabUnread",
            "palette.toggleFullWidthTab", "tab.muteOtherAudio", "agentChat.toggleNotificationMute",
            "hibernateTab", "wakeTab", "neverHibernateSite", "browser.resetPinnedTab",
            // Pane geometry, providers and diagnostics stay searchable; the menu keeps
            // its common actions, including target-dependent reconnect, remote and chat tools.
            "newPaneAutoLayout", "triggerFlash", "palette.swapWithSession", "toggleCanvasLayout", "palette.newSimulatorPane",
            "remote.openTerminalHere", "column.moveLeft", "column.moveRight", "column.center", "column.widthOneThird",
            "column.widthHalf", "column.widthTwoThirds", "column.widthFull", "column.dock", "column.undock", "column.float",
            "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
            // Docked workspaces are a default-off prototype (`window.dockedWorkspaces`): palette, CLI and MCP only,
            // so the workspace row's Move menu does not grow six rows nobody can use yet.
            "workspace.dockLeft", "workspace.dockRight", "workspace.dockTop", "workspace.dockBottom", "workspace.undock",
            "workspace.toggleDockFloating","workspace.setTint", "workspace.copyPath", "copyWorkspaceSSHError", "revealWorkspaceInFinder",
            "palette.copyWorkspaceIDAndRef", "workspace.showResources", "palette.openWorkspacePullRequests",
            "workspace.setRemoteLocalhost",
            // The tab menu's Move folder already holds Move Tab to Workspace…; a space list there would bloat it.
            "tab.moveToSpace"],
        .paletteInternal: [
            "commandPaletteNext", "commandPalettePrevious",
        ],
        .devOnly: [
            "openDebugSettings",
        ],
    ]
}
