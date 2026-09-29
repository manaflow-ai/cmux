/// One entry of a declared context menu.
public enum ContextMenuEntry: Sendable, Hashable {
    case action(ActionID)
    case separator
    /// A submenu titled by an action's title (without its ellipsis).
    case submenu(ActionID, [ContextMenuEntry])
}

/// Right-click menus declared as ordered action ID lists per context. The
/// registry renders them (`ActionRegistry.makeContextMenu`), so a menu never
/// hand-builds titles, shortcuts, or enabled state.
public enum ContextMenuCatalog {
    public static func entries(for context: ActionMenuContext) -> [ContextMenuEntry] {
        switch context {
        case .tab: tab
        case .tabGroup: tabGroup
        case .pane: pane
        case .column: column
        case .workspaceRow: workspaceRow
        case .workspaceGroup: workspaceGroup
        case .sidebarBackground: sidebarBackground
        case .terminalSelection: terminalSelection
        case .browserPage: browserPage
        case .link: link
        case .cloudMachine: cloudMachine
        }
    }

    /// Every action ID an entry list references, submenus included.
    public static func referencedIDs(_ entries: [ContextMenuEntry]) -> [ActionID] {
        entries.flatMap { entry -> [ActionID] in
            switch entry {
            case .action(let id): [id]
            case .separator: []
            case .submenu(let id, let children): [id] + referencedIDs(children)
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

    static let tab: [ContextMenuEntry] =
        actions("newSurface", "openBrowser", "duplicateTab", "reloadTab") + [.separator]
        + actions("renameTab", "palette.clearTabName", "palette.toggleTabPin", "palette.toggleTabUnread", "toggleTabAudioMute")
        + [.separator] + actions("tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab") + [.separator]
        + actions("moveSurfaceToPaneLeft", "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPaneDown",
                  "tab.moveToNewSplit", "tab.moveToNewColumn", "palette.moveTabToNewWorkspace", "tab.moveToNewWindow",
                  "palette.toggleFullWidthTab")
        + [.separator] + actions("palette.copySurfaceID", "palette.copySurfaceLink", "palette.copyIdentifiers")
        + [.separator] + actions("disconnectRemoteTab", "closeTabsToLeft", "closeTabsToRight", "closeOtherTabsInPane", "closeTab")

    static let tabGroup: [ContextMenuEntry] =
        actions("tabGroup.newTab", "tabGroup.rename") + [.submenu("tabGroup.setColor", colors("tabGroup"))]
        + actions("tabGroup.toggleCollapsed") + [.separator] + actions("tabGroup.save", "tabGroup.unsave") + [.separator]
        + actions("tabGroup.moveLeft", "tabGroup.moveRight", "tabGroup.moveToNewSplit", "tabGroup.moveToNewColumn", "tabGroup.moveToNewWorkspace",
                  "tabGroup.moveToWorkspace", "tabGroup.moveToNewWindow")
        + [.separator] + actions("tabGroup.ungroup", "tabGroup.close")

    static let pane: [ContextMenuEntry] =
        actions("splitRight", "splitDown", "splitLeft", "splitUp", "newColumn", "splitBrowserRight", "splitBrowserDown")
        + [.separator] + actions("toggleSplitZoom", "equalizeSplits", "triggerFlash", "renamePane") + [.separator]
        + actions("palette.swapWithSession", "reconnectPane") + [.separator]
        + actions("palette.copyPaneID", "palette.copyPaneLink") + [.separator] + actions("closePane")

    static let column: [ContextMenuEntry] =
        actions("newColumn", "newPaneAutoLayout", "splitDown") + [.separator]
        + actions("column.widthOneThird", "column.widthHalf", "column.widthTwoThirds", "column.widthFull") + [.separator]
        + actions("column.moveLeft", "column.moveRight", "equalizeSplits", "toggleSplitZoom")

    static let workspaceRow: [ContextMenuEntry] =
        actions("renameWorkspace", "editWorkspaceDescription", "palette.workspaceStatus", "markWorkspaceDone",
                "palette.workspaceColor", "palette.resetWorkspaceColor", "palette.toggleWorkspacePin",
                "palette.markWorkspaceRead", "palette.markWorkspaceUnread")
        + [.separator]
        + actions("moveWorkspaceUp", "moveWorkspaceDown", "palette.moveWorkspaceToTop", "moveWorkspaceToWindow",
                  "moveWorkspaceToGroup", "removeWorkspaceFromGroup")
        + [.separator]
        + actions("reconnectWorkspace", "disconnectWorkspace", "revealWorkspaceInFinder", "palette.copyWorkspaceID",
                  "palette.copyWorkspaceLink")
        + [.separator]
        + actions("palette.closeOtherWorkspaces", "palette.closeWorkspacesBelow", "palette.closeWorkspacesAbove", "closeWorkspace")

    static let cloudMachine: [ContextMenuEntry] =
        actions("cloudNewTerminal", "cloudOpenMachine", "cloudRenameMachine") + [.separator]
        + actions("cloudCopyMachineID", "cloudCopyLink", "cloudCopyPort") + [.separator]
        + actions("cloudResizeMachine", "palette.cloud.status", "palette.cloud.snapshot", "palette.cloud.fork") + [.separator]
        + actions("cloudKillMachine")

    static let workspaceGroup: [ContextMenuEntry] =
        actions("workspaceGroup.newWorkspace", "workspaceGroup.rename")
        + [.submenu("workspaceGroup.setColor", colors("workspaceGroup"))]
        + actions("workspaceGroup.togglePin", "toggleFocusedWorkspaceGroupCollapsed") + [.separator]
        + actions("workspaceGroup.markRead", "workspaceGroup.markUnread", "workspaceGroup.clearNotifications") + [.separator]
        + actions("workspaceGroup.moveUp", "workspaceGroup.moveDown", "workspaceGroup.moveToNewWindow",
                  "workspaceGroup.moveToWindow")
        + [.separator] + actions("workspaceGroup.editConfig") + [.separator]
        + actions("workspaceGroup.ungroup", "workspaceGroup.closeWorkspaces", "workspaceGroup.delete")

    static let sidebarBackground: [ContextMenuEntry] =
        actions("newTab", "newBrowserWorkspace", "openFolder", "newWorkspaceGroup") + [.separator]
        + actions("newCloudWorkspace") + [.separator] + actions("toggleSidebar")

    static let terminalSelection: [ContextMenuEntry] =
        actions("terminalCopy", "terminalPaste", "useSelectionForFind") + [.separator]
        + actions("palette.forkAgentConversationRight", "palette.forkAgentConversationNewTab") + [.separator]
        + actions("clearScreenKeepScrollback", "resetTerminal")

    static let browserPage: [ContextMenuEntry] =
        actions("browserBack", "browserForward", "browserReload") + [.separator]
        + actions("palette.browserOpenDefault", "browserScreenshotPage", "browserScreenshotSection") + [.separator]
        + actions("toggleBrowserDeveloperTools")

    static let link: [ContextMenuEntry] =
        actions("openLinkInNewTab", "openLinkInDefaultBrowser") + [.separator] + actions("terminalCopy")
}
