/// One entry of a declared context menu.
public enum ContextMenuEntry: Sendable, Hashable {
    case action(ActionID)
    case separator
    /// A submenu titled by an action's title (without its ellipsis).
    case submenu(ActionID, [ContextMenuEntry])
    /// A submenu titled by an action, one item per value of its first
    /// enumeration argument (Set Room Theme > Nord, Vesper, ...). Hovering
    /// an item previews it (`ActionRegistry.choicePreview`).
    case choices(ActionID)
}

/// Right-click menus declared as ordered action ID lists per context. The
/// registry renders them (`ActionRegistry.makeContextMenu`), so a menu never
/// hand-builds titles, shortcuts, or enabled state.
public enum ContextMenuCatalog {
    public static func entries(for context: ActionMenuContext) -> [ContextMenuEntry] {
        switch context {
        case .tab: tab
        case .tabGroup: tabGroup
        case .screen: screen
        case .screenGroup: screenGroup
        case .pane: pane
        case .column: column
        case .workspaceRow: workspaceRow
        case .workspaceGroup: workspaceGroup
        case .sidebarBackground: sidebarBackground
        case .terminalSelection: terminalSelection
        case .browserPage: browserPage
        case .link: link
        case .cloudMachine: cloudMachine
        case .sshMachine: sshMachine
        case .newTab: newTab
        case .profile: profile
        }
    }

    /// Every action ID an entry list references, submenus included.
    public static func referencedIDs(_ entries: [ContextMenuEntry]) -> [ActionID] {
        entries.flatMap { entry -> [ActionID] in
            switch entry {
            case .action(let id): [id]
            case .separator: []
            case .submenu(let id, let children): [id] + referencedIDs(children)
            case .choices(let id): [id]
            }
        }
    }

    private static func actions(_ ids: ActionID...) -> [ContextMenuEntry] {
        ids.map { .action($0) }
    }

    private static func colors(_ prefix: String) -> [ContextMenuEntry] {
        ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
            .map { .action(ActionID(rawValue: "\(prefix).color.\($0)")) }
    }

    /// The + button: one entry per tab kind. Chromium shows disabled, with
    /// its reason, when this build has no CEF runtime.
    static let newTab: [ContextMenuEntry] =
        actions("newSurface", "openBrowser.webkit", "openBrowser.chromium")

    static let tab: [ContextMenuEntry] =
        actions("newSurface", "openBrowser.webkit", "openBrowser.chromium", "duplicateTab", "reloadTab") + [.separator]
        + actions("browser.openInChromium", "browser.openInWebKit") + [.separator]
        + actions("renameTab", "palette.clearTabName", "palette.toggleTabPin", "palette.toggleTabUnread", "toggleTabAudioMute")
        + [.choices("terminal.setTheme")] + actions("terminal.clearTheme")
        + [.separator] + actions("tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab") + [.separator]
        + actions("moveSurfaceToPaneLeft", "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPaneDown",
                  "tab.moveToNewSplit", "tab.moveToNewColumn", "palette.moveTabToNewWorkspace", "tab.moveToNewWindow",
                  "palette.toggleFullWidthTab")
        + [.separator] + actions("tab.showResources", "palette.copySurfaceID", "palette.copySurfaceLink", "palette.copyIdentifiers")
        + [.separator] + actions("disconnectRemoteTab", "closeTabsToLeft", "closeTabsToRight", "closeOtherTabsInPane", "closeTab")

    static let tabGroup: [ContextMenuEntry] =
        actions("tabGroup.newTab", "tabGroup.rename") + [.submenu("tabGroup.setColor", colors("tabGroup"))]
        + actions("tabGroup.toggleCollapsed") + [.separator] + actions("tabGroup.save", "tabGroup.unsave") + [.separator]
        + actions("tabGroup.moveLeft", "tabGroup.moveRight", "tabGroup.moveToNewSplit", "tabGroup.moveToNewColumn", "tabGroup.moveToNewWorkspace",
                  "tabGroup.moveToWorkspace", "tabGroup.moveToNewWindow")
        + [.separator] + actions("tabGroup.ungroup", "tabGroup.close")

    /// A screen tab in the bottom screen bar.
    static let screen: [ContextMenuEntry] =
        actions("screen.new", "screen.duplicate") + [.separator]
        + actions("screen.rename") + [.submenu("screen.setColor", colors("screen") + actions("screen.clearColor"))]
        + actions("screen.setIcon", "screen.clearIcon", "screen.togglePin") + [.separator]
        + actions("screenGroup.create", "screenGroup.addScreen", "screenGroup.removeScreen") + [.separator]
        + actions("screen.moveLeft", "screen.moveRight", "screen.moveToWorkspace", "screen.moveToNewWorkspace", "screen.moveToNewWindow")
        + [.separator] + actions("screen.close", "screen.closeOthers", "screen.closeToRight", "screen.closeToLeft")

    /// A screen group chip in the screen bar.
    static let screenGroup: [ContextMenuEntry] =
        actions("screenGroup.newScreen", "screenGroup.rename") + [.submenu("screenGroup.setColor", colors("screenGroup"))]
        + actions("screenGroup.toggleCollapsed") + [.separator] + actions("screenGroup.save", "screenGroup.unsave") + [.separator]
        + actions("screenGroup.moveLeft", "screenGroup.moveRight", "screenGroup.moveToWorkspace", "screenGroup.moveToNewWorkspace",
                  "screenGroup.moveToNewWindow")
        + [.separator] + actions("screenGroup.ungroup", "screenGroup.close")

    static let pane: [ContextMenuEntry] =
        actions("splitRight", "splitDown", "splitLeft", "splitUp", "newColumn", "splitBrowserRight", "splitBrowserDown")
        + [.separator] + actions("toggleSplitZoom", "equalizeSplits", "triggerFlash", "renamePane") + [.separator]
        + actions("palette.swapWithSession", "reconnectPane") + [.separator]
        + actions("pane.moveToNewWorkspace") + [.separator]
        + actions("palette.copyPaneID", "palette.copyPaneLink") + [.separator] + actions("closePane")

    static let column: [ContextMenuEntry] =
        actions("newColumn", "newPaneAutoLayout", "splitDown") + [.separator]
        + actions("column.widthOneThird", "column.widthHalf", "column.widthTwoThirds", "column.widthFull") + [.separator]
        + actions("column.moveLeft", "column.moveRight", "equalizeSplits", "toggleSplitZoom")

    static let workspaceRow: [ContextMenuEntry] =
        actions("workspace.newAbove", "workspace.newBelow", "workspace.newInGroup", "workspace.newInSameDirectory",
                "workspace.duplicate", "workspace.duplicateTerminalsOnly")
        + [.separator]
        + actions("renameWorkspace", "editWorkspaceDescription", "palette.workspaceStatus", "markWorkspaceDone",
                "palette.workspaceColor", "palette.resetWorkspaceColor", "workspace.setIcon", "workspace.clearIcon")
        + [.choices("workspace.setTheme")] + actions("workspace.clearTheme",
                "palette.toggleWorkspacePin", "palette.markWorkspaceRead", "palette.markWorkspaceUnread",
                "notifications.toggleWorkspaceMute")
        + [.separator]
        + actions("moveWorkspaceUp", "moveWorkspaceDown", "palette.moveWorkspaceToTop", "workspace.moveToBottom", "moveWorkspaceToWindow",
                  "moveWorkspaceToNewWindow", "moveWorkspaceToGroup", "workspace.moveToNewGroup", "removeWorkspaceFromGroup",
                  "workspace.moveToRoom", "workspace.duplicateToRoom", "workspace.mergeInto")
        + [.separator]
        + actions("workspace.showResources", "reconnectWorkspace", "disconnectWorkspace", "revealWorkspaceInFinder", "workspace.copyPath",
                  "palette.copyWorkspaceID", "palette.copyWorkspaceLink")
        + [.separator]
        + actions("palette.closeOtherWorkspaces", "workspace.closeOthersInGroup", "palette.closeWorkspacesBelow", "palette.closeWorkspacesAbove",
                  "closeWorkspace")

    static let cloudMachine: [ContextMenuEntry] =
        actions("cloudNewTerminal", "cloudOpenMachine", "cloudRenameMachine") + [.separator]
        + actions("cloudCopyMachineID", "cloudCopyLink", "cloudCopyPort") + [.separator]
        + actions("cloudResizeMachine", "palette.cloud.status", "palette.cloud.snapshot", "palette.cloud.fork") + [.separator]
        + actions("cloudKillMachine")

    /// An SSH machine's section header.
    static let sshMachine: [ContextMenuEntry] =
        actions("remote.newWorkspace") + [.separator]
        + actions("remote.reconnect", "remote.disconnect", "remote.install") + [.separator]
        + actions("remote.forget")

    /// A room dot in the sidebar.
    static let profile: [ContextMenuEntry] =
        actions("room.newWindow", "room.newWorkspace") + [.separator]
        + actions("room.rename")
        + [.submenu("room.setColor", colors("room") + [.separator] + actions("room.clearColor"))]
        + actions("room.setIcon", "room.clearIcon")
        + [.choices("room.setTheme")] + actions("room.clearTheme", "room.setDefaults") + [.separator]
        + actions("room.moveLeft", "room.moveRight") + [.separator]
        + actions("room.new") + [.separator] + actions("room.delete")

    static let workspaceGroup: [ContextMenuEntry] =
        actions("workspaceGroup.newWorkspace", "workspaceGroup.rename")
        + [.submenu("workspaceGroup.setColor", colors("workspaceGroup"))]
        + actions("workspaceGroup.togglePin", "toggleFocusedWorkspaceGroupCollapsed") + [.separator]
        + actions("workspaceGroup.markRead", "workspaceGroup.markUnread", "workspaceGroup.clearNotifications") + [.separator]
        + actions("workspaceGroup.collapseAll", "workspaceGroup.expandAll") + [.separator]
        + actions("workspaceGroup.moveUp", "workspaceGroup.moveDown", "workspaceGroup.moveToNewWindow",
                  "workspaceGroup.moveToWindow", "workspaceGroup.moveToRoom")
        + [.separator] + actions("workspaceGroup.editConfig") + [.separator]
        + actions("workspaceGroup.ungroup", "workspaceGroup.closeWorkspaces", "workspaceGroup.delete")

    static let sidebarBackground: [ContextMenuEntry] =
        actions("newTab", "workspace.newAtTop", "workspace.newOnMachine", "newBrowserWorkspace", "openFolder", "newWorkspaceGroup", "room.new")
        + [.separator]
        + actions("workspace.sortByName", "workspace.sortByLastUsed", "workspace.sortByDirectory", "workspaceGroup.collapseAll",
                  "workspaceGroup.expandAll") + [.separator]
        + actions("newCloudWorkspace", "remote.connect") + [.separator] + actions("toggleSidebar")

    static let terminalSelection: [ContextMenuEntry] =
        actions("terminalCopy", "terminalPaste", "terminal.selectAll", "useSelectionForFind") + [.separator]
        + actions("splitRight", "splitDown", "splitLeft", "splitUp", "toggleSplitZoom") + [.separator]
        + actions("palette.forkAgentConversationRight", "palette.forkAgentConversationNewTab") + [.separator]
        + actions("clearScreenKeepScrollback", "resetTerminal")

    static let browserPage: [ContextMenuEntry] =
        actions("browserBack", "browserForward", "browserReload") + [.separator]
        + actions("palette.browserOpenDefault", "browserScreenshotPage", "browserScreenshotSection") + [.separator]
        + [.submenu("browser.pageInfo", pageInfo)] + actions("toggleBrowserDeveloperTools") + [.separator]
        + actions("browser.extensions.menu", "browser.extensions.manage")

    /// Every Page Info control (the omnibar's site information bubble).
    static let pageInfo: [ContextMenuEntry] =
        actions("browser.pageInfo", "browser.pageInfo.connection", "browser.pageInfo.certificate") + [.separator]
        + actions("browser.pageInfo.setPermission", "browser.pageInfo.resetPermissions") + [.separator]
        + actions("browser.pageInfo.cookies", "browser.pageInfo.manageSiteData", "browser.pageInfo.deleteSiteData") + [.separator]
        + actions("browser.pageInfo.siteSettings", "browser.pageInfo.aboutThisPage")

    /// The cmux items after an engine's own page menu (Chromium lists Back,
    /// Forward and Reload itself): the page menu without that group.
    public static let browserPageAfterEngineMenu: [ContextMenuEntry] = {
        let navigation: Set<ActionID> = ["browserBack", "browserForward", "browserReload"]
        var entries = browserPage.filter { if case .action(let id) = $0 { !navigation.contains(id) } else { true } }
        while case .separator? = entries.first { entries.removeFirst() }
        return entries
    }()

    static let link: [ContextMenuEntry] =
        actions("openLinkInNewTab", "openLinkInDefaultBrowser") + [.separator] + actions("terminalCopy")
}
