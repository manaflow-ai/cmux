/// How the command palette orders the catalog (plans/cmux-next/palette-ranking.md 5.4, the
/// palette audit). Nothing here hides an action: every action stays a search result, a CLI verb
/// and an MCP tool. A tier moves a row up or down among rows that match a query equally well; a
/// family folds related rows into one row on the empty query, and the members still match when
/// typed. Catalog data, checked by `PaletteRankCatalogTests`.
public nonisolated enum PaletteTier: Int, Sendable, Hashable, Comparable {
    /// Used most days: first in its section, and ahead of an equal match while typing.
    case daily
    case standard
    /// Valid but rarely wanted (an ID copy, a diagnostic, one value of a family): last in its
    /// section, and behind an equal match while typing.
    case niche

    public static func < (lhs: PaletteTier, rhs: PaletteTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Related actions the empty palette shows as one row. With a `parent` (Set Space Color… for the
/// nine colors, Toggle Developer Tools for the Developer Tools commands) the parent's row stands
/// for them; without one the palette draws a row titled `title` that opens a page of the members
/// (Workspace: Move… for the ten moves). A duplicate is a family of one: its row folds into the
/// row people know, which matches its words too.
public nonisolated struct PaletteFamily: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let parent: ActionID?
    public let members: [ActionID]

    init(_ id: String, title: String, symbol: String, members: [ActionID]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        parent = nil
        self.members = members
    }

    init(_ id: String, parent: ActionID, members: [ActionID]) {
        self.id = id
        title = ""
        symbol = ""
        self.parent = parent
        self.members = members
    }
}

extension ActionDescriptor {
    /// Daily commands: what a person reaches for in the palette most days.
    nonisolated static let paletteDailyActions: Set<ActionID> = [
        "newTab", "newTab.default", "newWindow", "closeTab", "closeWorkspace", "closePane", "splitRight", "splitDown",
        "openBrowser", "palette.newAgentChat", "palette.quickAgentChat", "openSettings", "goToWorkspace", "tab.search",
        "search.chats", "globalSearch", "find", "findInDirectory", "renameWorkspace", "renameTab", "toggleSidebar",
        "toggleRightSidebar", "toggleSplitZoom", "equalizeSplits", "openFolder", "file.open", "reopenClosedBrowserPanel",
        "reopenClosedWorkspace", "recentlyClosed", "jumpToUnread", "openDiffViewer", "terminal.setTheme",
        "appearance.customize", "appearance.changeBackground", "terminal.increaseFontSize", "terminal.decreaseFontSize",
        "remote.connect", "workspace.newOnMachine", "newCloudWorkspace", "keybindings.open", "palette.checkForUpdates",
        "palette.toggleSetting", "reloadConfiguration",
    ]

    /// Valid but rarely wanted. Family members and duplicates are niche without being listed.
    nonisolated static let paletteNicheActions: Set<ActionID> = [
        // IDs and links for scripts: the CLI prints them too.
        "palette.copyWorkspaceID", "palette.copyWorkspaceIDAndRef", "palette.copyPaneID", "palette.copySurfaceID",
        "palette.copyIdentifiers", "workspaceGroup.copyID", "cloudCopyMachineID", "agentChat.copyIdentifier",
        // Diagnostics, recovery and one-time setup.
        "palette.restartSocketListener", "palette.restartServer", "palette.attemptUpdate", "openDebugSettings",
        "help.featureFlags", "help.showCrashLogs", "ghostty.showDiagnostics", "home.saveFlightRecording",
        "taskManager.killProcess", "palette.installCLI", "palette.uninstallCLI", "palette.makeDefaultBrowser",
        "palette.makeDefaultTerminal", "palette.switchAppChannel", "updates.rollback", "palette.shortcutKeymap",
        "workspace.importClassic", "palette.computerUse.accessibility", "palette.computerUse.screenRecording",
        "palette.vscodeServeWebStop", "palette.vscodeServeWebRestart", "palette.disableBrowser", "palette.enableBrowser",
        "server.makeThisMacAServer", "server.stopServing", "sendCtrlFToTerminal", "toggleReactGrab",
        // Prompts and warnings a page shows its own buttons for.
        "browser.certificateWarning.goBack", "browser.certificateWarning.proceed", "browser.prompt.allow",
        "browser.prompt.block", "browser.download.openBlockedSiteSettings",
        // Quit variants: Quit cmux is the one people use.
        "quitEndEverything", "quitEndSessions", "quitKeepSessions",
        // Preferences that Settings shows better.
        "announcements.show", "announcements.hide", "nowPlaying.showCard", "nowPlaying.disableCard",
        "nowPlaying.hideCardUntilRelaunch", "sidebar.profileControl.show", "sidebar.profileControl.hide",
        "tabs.overflow.scroll", "tabs.overflow.shrink", "links.openInCmuxBrowser", "links.openInDefaultBrowser",
        "links.signInPagesInCmux", "links.signInPagesByLinkSettings",
        "browser.defaultEngine.chromium", "browser.defaultEngine.webkit", "layout.centerFocusedColumn.always",
        "layout.centerFocusedColumn.never", "layout.centerFocusedColumn.onOverflow", "layout.toggleStripScrollbar",
        "appearance.titlebar.minimal", "appearance.titlebar.standard", "increaseWorkspaceTerminalFontSize",
        "decreaseWorkspaceTerminalFontSize", "resetWorkspaceTerminalFontSize",
        // Interface Size is a Debug opt-in (chrome.interfaceSize); Interface Scale is the setting.
        "appearance.interfaceSize.increase", "appearance.interfaceSize.decrease", "appearance.interfaceSize.reset",
        // Cloud machine plumbing.
        "cloudPrepareSCP", "cloudDomainList", "cloudNetworkList", "cloudPublicationList", "palette.cloud.promoteTemplate",
    ]

    /// Built-in palette aliases: a query that is one of these words puts the action first (as a
    /// cmux.json `palette.aliases` entry does), and the word matches it as a keyword while typing.
    nonisolated public static let paletteAliases: [ActionID: [String]] = [
        "appearance.customize": ["font", "theme", "background"],
        "terminal.increaseFontSize": ["font"],
        "terminal.decreaseFontSize": ["font"],
        "terminal.resetFontSize": ["font"],
        "terminal.setTheme": ["theme"],
        "workspace.setTheme": ["theme"],
        "browserTheme": ["theme"],
        "appearance.changeBackground": ["background", "wallpaper"],
        "pane.setBackground": ["background"],
        "remote.connect": ["machine", "ssh"],
        "workspace.newOnMachine": ["machine"],
        "newCloudMachine": ["machine"],
        "switchRightSidebarToMachines": ["machine", "machines"],
    ]

    nonisolated public static let paletteFamilies: [PaletteFamily] = [
        PaletteFamily("workspace.move", title: familyTitle("palette.family.workspace.move", "Workspace: Move…"),
                      symbol: "arrow.up.arrow.down", members: [
                          "moveWorkspaceUp", "moveWorkspaceDown", "palette.moveWorkspaceToTop", "workspace.moveToBottom",
                          "moveWorkspaceToGroup", "workspace.moveToNewGroup", "removeWorkspaceFromGroup", "moveWorkspaceToWindow",
                          "moveWorkspaceToNewWindow", "workspace.moveToSpace",
                      ]),
        PaletteFamily("workspace.new", title: familyTitle("palette.family.workspace.new", "Workspace: New or Duplicate…"),
                      symbol: "plus.square.on.square", members: [
                          "workspace.newAbove", "workspace.newBelow", "workspace.newAtTop", "workspace.newAtBottom",
                          "workspace.newInNewGroup", "workspace.newLikeThis", "workspace.duplicate",
                          "workspace.duplicateTerminalsOnly", "workspace.duplicateToSpace",
                      ]),
        PaletteFamily("workspace.close", title: familyTitle("palette.family.workspace.close", "Workspace: Close Several…"),
                      symbol: "xmark.square", members: [
                          "palette.closeOtherWorkspaces", "palette.closeWorkspacesAbove", "palette.closeWorkspacesBelow",
                          "workspace.closeAll", "workspace.closeAllInAllWindows", "workspace.closeOthersInGroup",
                      ]),
        PaletteFamily("workspace.sort", title: familyTitle("palette.family.workspace.sort", "Workspace: Sort…"),
                      symbol: "arrow.up.arrow.down.square", members: [
                          "workspace.sortByDirectory", "workspace.sortByLastUsed", "workspace.sortByName",
                      ]),
        PaletteFamily("workspaceGroup.move", title: familyTitle("palette.family.workspaceGroup.move", "Workspace Group: Move…"),
                      symbol: "arrow.up.arrow.down", members: [
                          "workspaceGroup.moveUp", "workspaceGroup.moveDown", "workspaceGroup.moveToTop",
                          "workspaceGroup.moveToBottom", "workspaceGroup.moveToNewWindow", "workspaceGroup.moveToWindow",
                          "workspaceGroup.moveToSpace",
                      ]),
        PaletteFamily("workspaceGroup.sort", title: familyTitle("palette.family.workspaceGroup.sort", "Workspace Group: Sort…"),
                      symbol: "arrow.up.arrow.down.square", members: [
                          "workspaceGroup.sortByDirectory", "workspaceGroup.sortByLastUsed", "workspaceGroup.sortByName",
                      ]),
        PaletteFamily("tab.move", title: familyTitle("palette.family.tab.move", "Tab: Move…"),
                      symbol: "arrow.left.arrow.right", members: [
                          "moveSurfaceLeft", "moveSurfaceRight", "moveSurfaceToNextPane", "moveSurfaceToPreviousPane",
                          "moveSurfaceToPaneUp", "moveSurfaceToPaneDown", "moveSurfaceToPaneLeft", "moveSurfaceToPaneRight",
                          "tab.moveToNewSplit", "tab.moveToNewColumn", "tab.moveToNewDockColumn", "tab.moveToNewWindow",
                          "tab.moveToWorkspace", "palette.moveTabToNewWorkspace",
                      ]),
        PaletteFamily("tab.new", title: familyTitle("palette.family.tab.new", "Tab: New in Position…"),
                      symbol: "plus.rectangle.on.rectangle", members: [
                          "newTab.afterCurrent", "newTab.atEnd", "newTab.atStart", "newTab.toRight", "newTab.horizontal",
                          "newTab.ofKind",
                      ]),
        PaletteFamily("tab.close", title: familyTitle("palette.family.tab.close", "Tab: Close Several…"),
                      symbol: "xmark.rectangle", members: [
                          "closeOtherTabsInPane", "closeTabsToLeft", "closeTabsToRight",
                      ]),
        PaletteFamily("tabGroup.move", title: familyTitle("palette.family.tabGroup.move", "Tab Group: Move…"),
                      symbol: "arrow.left.arrow.right", members: [
                          "tabGroup.moveLeft", "tabGroup.moveRight", "tabGroup.moveToNewColumn", "tabGroup.moveToNewSplit",
                          "tabGroup.moveToNewWindow", "tabGroup.moveToNewWorkspace", "tabGroup.moveToWorkspace",
                      ]),
        PaletteFamily("screen.move", title: familyTitle("palette.family.screen.move", "Screen: Move…"),
                      symbol: "arrow.left.arrow.right", members: [
                          "screen.moveLeft", "screen.moveRight", "screen.moveToNewWindow", "screen.moveToNewWorkspace",
                          "screen.moveToWorkspace",
                      ]),
        PaletteFamily("screen.close", title: familyTitle("palette.family.screen.close", "Screen: Close Several…"),
                      symbol: "xmark.rectangle", members: [
                          "screen.closeOthers", "screen.closeToLeft", "screen.closeToRight",
                      ]),
        PaletteFamily("screenGroup.move", title: familyTitle("palette.family.screenGroup.move", "Screen Group: Move…"),
                      symbol: "arrow.left.arrow.right", members: [
                          "screenGroup.moveLeft", "screenGroup.moveRight", "screenGroup.moveToNewWindow",
                          "screenGroup.moveToNewWorkspace", "screenGroup.moveToWorkspace",
                      ]),
        PaletteFamily("pane.swap", title: familyTitle("palette.family.pane.swap", "Pane: Swap…"),
                      symbol: "rectangle.2.swap", members: [
                          "swapPaneLeft", "swapPaneRight", "swapPaneUp", "swapPaneDown", "palette.swapWithSession",
                      ]),
        PaletteFamily("pane.resize", title: familyTitle("palette.family.pane.resize", "Pane: Resize…"),
                      symbol: "arrow.up.left.and.arrow.down.right", members: [
                          "resizePaneLeft", "resizePaneRight", "resizePaneUp", "resizePaneDown",
                      ]),
        PaletteFamily("column.width", title: familyTitle("palette.family.column.width", "Column: Width…"),
                      symbol: "arrow.left.and.right", members: [
                          "column.widthOneThird", "column.widthHalf", "column.widthTwoThirds", "column.widthFull",
                          "column.cycleWidth", "column.cycleWidthBack",
                      ]),
        PaletteFamily("column.dock", title: familyTitle("palette.family.column.dock", "Column: Dock or Float…"),
                      symbol: "dock.rectangle", members: [
                          "column.dock", "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
                          "column.float", "column.undock",
                      ]),
        PaletteFamily("canvas.arrange", title: familyTitle("palette.family.canvas.arrange", "Canvas: Align and Distribute…"),
                      symbol: "align.horizontal.left", members: [
                          "canvasAlignLeft", "canvasAlignRight", "canvasAlignTop", "canvasAlignBottom",
                          "canvasDistributeHorizontally", "canvasDistributeVertically", "canvasEqualizeWidths",
                          "canvasEqualizeHeights",
                      ]),
        PaletteFamily("phone", title: familyTitle("palette.family.phone", "Phone: All Commands…"),
                      symbol: "iphone", members: [
                          "phone.boot", "phone.shutdown", "phone.list", "phone.screenshot", "phone.recordStart",
                          "phone.recordStop", "phone.sendFeedback", "phone.openURL", "phone.paste", "phone.tap", "phone.swipe",
                          "phone.type", "phone.button", "phone.ui", "phone.appearance", "phone.location", "phone.locale",
                          "phone.install", "phone.launch", "phone.rotate", "phone.logs",
                      ]),
        PaletteFamily("cloud.files", title: familyTitle("palette.family.cloud.files", "Cloud Machine: Files and Network…"),
                      symbol: "network", members: [
                          "cloudFilesList", "cloudFileRead", "cloudFileWrite", "cloudFileStat", "cloudFileMkdir",
                          "cloudFileRemove", "cloudFirewallList", "cloudFirewallGet", "cloudFirewallCreate",
                          "cloudFirewallDelete", "cloudTunnelAttach", "cloudTunnelDetach", "cloudTunnelRotateKey",
                      ]),
        PaletteFamily("bookmarks", title: familyTitle("palette.family.bookmarks", "Bookmarks: All Commands…"),
                      symbol: "bookmark", members: [
                          "bookmark.add", "bookmark.addAllTabs", "bookmark.newFolder", "bookmark.openInNewTab",
                          "bookmark.openInBackgroundTab", "bookmark.openAll", "bookmark.copyLink", "bookmark.edit",
                          "bookmark.move", "bookmark.remove", "bookmark.import", "bookmark.importFromBrowser",
                          "bookmark.export", "bookmark.setIcon", "bookmark.clearIcon",
                      ]),
        PaletteFamily("browserProfile", title: familyTitle("palette.family.browserProfile", "Browser Profile: All Commands…"),
                      symbol: "person.crop.square", members: [
                          "browserProfile.new", "browserProfile.rename", "browserProfile.delete", "browserProfile.setColor",
                          "browserProfile.clearColor", "browserProfile.setIcon", "browserProfile.clearIcon",
                          "browserProfile.newTab", "browserProfile.newWindow", "browserProfile.newWorkspace",
                          "browserProfile.openLink", "browserProfile.moveTab", "browserProfile.duplicateTab",
                          "browserProfile.setWorkspaceDefault", "browserProfile.clearWorkspaceDefault",
                          "browserProfile.setSpaceDefault", "browserProfile.clearSpaceDefault",
                          "browserProfile.clearBrowsingData", "browserProfile.manageExtensions",
                      ]),
        PaletteFamily("animations", title: familyTitle("palette.family.animations", "Animations…"),
                      symbol: "wand.and.rays", members: [
                          "appearance.animations.toggle", "appearance.animationSpeed.off", "appearance.animationSpeed.normal",
                          "appearance.animationSpeed.fast", "appearance.animations.bounce.none",
                          "appearance.animations.bounce.subtle", "appearance.animations.cursor.toggle",
                          "appearance.animations.feedback.toggle", "appearance.animations.home.toggle",
                          "appearance.animations.hoverCards.toggle", "appearance.animations.indicators.toggle",
                          "appearance.animations.newTab.toggle", "appearance.animations.newWorkspace.toggle",
                          "appearance.animations.overlays.toggle", "appearance.animations.panes.toggle",
                          "appearance.animations.sidebar.toggle", "appearance.animations.tabs.toggle",
                          "appearance.animations.web.toggle",
                      ]),
        PaletteFamily("windowStyle", title: familyTitle("palette.family.windowStyle", "Window Style…"),
                      symbol: "macwindow", members: [
                          "appearance.chromeStyle.default", "appearance.chromeStyle.bare", "appearance.chromeStyle.card",
                          "appearance.chromeStyle.cardOutlined", "appearance.chromeStyle.flat",
                          "appearance.chromeStyle.flatSidebarLine", "appearance.chromeStyle.floating",
                          "appearance.chromeStyle.panes", "appearance.chromeStyle.twoTone",
                      ]),
        PaletteFamily("paneChrome", title: familyTitle("palette.family.paneChrome", "Pane Borders and Focus Ring…"),
                      symbol: "square.dashed", members: [
                          "appearance.paneBorder.toggle", "appearance.paneBorderWidth.toggle",
                          "appearance.paneBorderColor.reset", "appearance.paneCorners.toggle", "appearance.panePadding.toggle",
                          "focusRing.toggle", "focusRing.singlePane.toggle", "focusRing.style.glow", "focusRing.style.ring",
                      ]),
        PaletteFamily("hibernation", title: familyTitle("palette.family.hibernation", "Tab Hibernation…"),
                      symbol: "moon.zzz", members: [
                          "browser.hibernation.off", "browser.hibernation.moderate", "browser.hibernation.aggressive",
                          "browser.keepNeighborTabsAwake.0", "browser.keepNeighborTabsAwake.1",
                          "browser.keepNeighborTabsAwake.2", "browser.keepNeighborTabsAwake.3",
                      ]),
        PaletteFamily("notificationClearing",
                      title: familyTitle("palette.family.notificationClearing", "Notifications: When to Clear…"),
                      symbol: "bell.badge", members: [
                          "notifications.dismissal.click", "notifications.dismissal.explicit", "notifications.dismissal.focus",
                          "notifications.dismissal.keystroke", "notifications.dismissal.never",
                          "notifications.dismissal.timeout",
                      ]),
        PaletteFamily("forkConversation", title: familyTitle("palette.family.forkConversation", "Fork Conversation…"),
                      symbol: "arrow.triangle.branch", members: [
                          "palette.forkAgentConversationRight", "palette.forkAgentConversationLeft",
                          "palette.forkAgentConversationTop", "palette.forkAgentConversationBottom",
                          "palette.forkAgentConversationNewTab", "palette.forkAgentConversationNewWorkspace",
                          "palette.forkAgentConversationNewWindow",
                      ]),
        PaletteFamily("sidebarSection", title: familyTitle("palette.family.sidebarSection", "Sidebar Section: Layout…"),
                      symbol: "sidebar.left", members: [
                          "sidebar.section.layoutList", "sidebar.section.layoutGrid", "sidebar.section.layoutInline",
                          "sidebar.section.setAlignment", "sidebar.section.setColumns", "sidebar.section.setGap",
                          "sidebar.section.setMaxRows", "sidebar.section.useBuiltInLook", "sidebar.section.useListLook",
                          "sidebar.section.toggleTitle", "sidebar.section.toggleSpaceScope", "sidebar.section.moveToTop",
                          "sidebar.section.moveToScrolling",
                      ]),
        // Families whose parent action already opens the choices.
        PaletteFamily("space.color", parent: "space.setColor", members: colors("space.color")),
        PaletteFamily("workspaceGroup.color", parent: "workspaceGroup.setColor", members: colors("workspaceGroup.color")),
        PaletteFamily("screen.color", parent: "screen.setColor", members: colors("screen.color")),
        PaletteFamily("screenGroup.color", parent: "screenGroup.setColor", members: colors("screenGroup.color")),
        PaletteFamily("tabGroup.color", parent: "tabGroup.setColor", members: colors("tabGroup.color")),
        PaletteFamily("density", parent: "appearance.density.set", members: [
            "appearance.density.ultraCompact", "appearance.density.compact", "appearance.density.cozy",
            "appearance.density.comfortable", "appearance.density.spacious",
        ]),
        PaletteFamily("devtools", parent: "toggleBrowserDeveloperTools", members: [
            "devtools.openDocked", "devtools.openDockedRight", "devtools.openInWindow", "devtools.close",
            "devtools.showElements", "devtools.showSources", "devtools.showNetwork", "devtools.showPerformance",
            "devtools.showMemory", "devtools.showApplication", "devtools.showSecurity", "devtools.showLighthouse",
            "devtools.showAnimations", "devtools.showLayers", "devtools.showRendering", "devtools.showSensors",
            "devtools.clearConsole", "devtools.copyConsoleLog", "devtools.clearSiteData", "devtools.emptyCacheAndHardReload",
            "devtools.captureScreenshot", "devtools.captureFullPageScreenshot", "devtools.captureNodeScreenshot",
            "devtools.pauseScript", "devtools.resumeScript", "devtools.takeHeapSnapshot",
            "devtools.togglePerformanceRecording", "devtools.viewPageSource", "devtools.toggleCSS", "devtools.toggleCache",
            "devtools.toggleJavaScript", "devtools.throttleOff", "devtools.throttleFast3G", "devtools.throttleSlow3G",
            "devtools.throttleOffline", "devtools.toggleFPSMeter", "devtools.toggleFocusEmulation",
            "devtools.toggleLayerBorders", "devtools.toggleLayoutShiftRegions", "devtools.togglePaintFlashing",
            "devtools.toggleReducedMotion",
        ]),
        PaletteFamily("extensions", parent: "browser.extensions.menu", members: [
            "browser.extension.command", "browser.extension.disable", "browser.extension.enable", "browser.extension.move",
            "browser.extension.options", "browser.extension.pin", "browser.extension.reload", "browser.extension.remove",
            "browser.extension.run", "browser.extension.unpin",
        ]),
        PaletteFamily("pageInfo", parent: "browser.pageInfo", members: [
            "browser.pageInfo.aboutThisPage", "browser.pageInfo.certificate", "browser.pageInfo.connection",
            "browser.pageInfo.cookies", "browser.pageInfo.deleteSiteData", "browser.pageInfo.manageSiteData",
            "browser.pageInfo.reenableCertificateWarnings", "browser.pageInfo.resetPermissions",
            "browser.pageInfo.setPermission", "browser.pageInfo.siteSettings",
        ]),
    ] + paletteDuplicates.sorted { $0.key.rawValue < $1.key.rawValue }
        .map { PaletteFamily("duplicate.\($0.key.rawValue)", parent: $0.value, members: [$0.key]) }

    /// Duplicates: the same command run on another target (an SSH machine's row, a sidebar app
    /// item), keyed by the duplicate. Both keep their own target, CLI verb and menu placement, and
    /// carry the canonical action's name on every surface (`PaletteMenuVocabularyTests`); the
    /// palette folds the duplicate into the canonical row, where its words still match. Actions
    /// that only sound alike are not duplicates: they get distinct names instead.
    nonisolated public static let paletteDuplicates: [ActionID: ActionID] = [
        "remote.newWorkspace": "workspace.newOnMachine",
        "remote.copyError": "copyWorkspaceSSHError",
        "sidebar.item.hideApp": "app.hide",
    ]

    /// The action whose name this one carries: itself unless it is a duplicate.
    nonisolated public var canonicalActionID: ActionID { Self.paletteDuplicates[id] ?? id }

    nonisolated static let paletteFamilyByMember: [ActionID: PaletteFamily] = {
        var byMember: [ActionID: PaletteFamily] = [:]
        for family in paletteFamilies {
            for member in family.members where byMember[member] == nil { byMember[member] = family }
        }
        return byMember
    }()

    /// The family whose row stands for this action on the empty query, or nil.
    nonisolated public var paletteFamily: PaletteFamily? { Self.paletteFamilyByMember[id] }

    nonisolated public var paletteTier: PaletteTier {
        if Self.paletteDailyActions.contains(id) { return .daily }
        if Self.paletteNicheActions.contains(id) || paletteFamily != nil { return .niche }
        return .standard
    }

    private nonisolated static func colors(_ prefix: String) -> [ActionID] {
        ["grey", "red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"]
            .map { ActionID(rawValue: "\(prefix).\($0)") }
    }

    private nonisolated static func familyTitle(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
