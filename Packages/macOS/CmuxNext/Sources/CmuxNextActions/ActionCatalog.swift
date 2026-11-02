/// The canonical action catalog: one descriptor per row of the old app's
/// action inventory (plans/cmux-next/inventory.md section 1) plus the tab
/// group and workspace group families (plans/cmux-next/architecture.md
/// section 7), one `ActionCatalogGroup` per domain in
/// `Catalog/<Domain>ActionCatalog.swift`. IDs match `KeyboardShortcutSettings.Action` raw values where one existed
/// (users store them in `cmux.json` `shortcuts`), else the old palette
/// command ID, else a new stable ID.
public nonisolated enum ActionCatalog {
    /// Every catalog descriptor, in inventory order.
    public static let all: [ActionDescriptor] = makeAll()

    /// IDs used by the cmux-next scaffold before the catalog existed, mapped
    /// to their canonical catalog ID. The registry folds these on register
    /// and lookup so older call sites keep working.
    public static let legacyAliases: [ActionID: ActionID] = [
        "app.quit": "quit",
        // Classic cmux shortcut IDs next renamed (hq#1870 parity audit): a binding
        // from classic's Settings or cmux.json keeps working.
        "showWindowHints": "hints.show",
        "agentInbox": "feed.show",
        "resize-pane-left": "resizePaneLeft",
        "resize-pane-right": "resizePaneRight",
        "resize-pane-up": "resizePaneUp",
        "resize-pane-down": "resizePaneDown",
        "diffViewerScrollDown": "diffViewerNextLine",
        "diffViewerScrollUp": "diffViewerPreviousLine",
        "diffViewerScrollHalfPageDown": "diffViewerHalfPageDown",
        "diffViewerScrollHalfPageUp": "diffViewerHalfPageUp",
        "diffViewerScrollToBottom": "diffViewerGoToBottom",
        "diffViewerScrollToTop": "diffViewerGoToTop",
        // Cmd-T's id named a setting value; it opens the New Tab page (cmuxterm-hq#1829).
        "newTab.sameKind": "newTab.default",
        // New Workspace Like This keeps the directory and the group (cmuxterm-hq#1829).
        "workspace.newInGroup": "workspace.newLikeThis",
        "workspace.newInSameDirectory": "workspace.newLikeThis",
        "tab.new": "newSurface",
        "tab.close": "closeTab",
        "tab.next": "nextSurface",
        "tab.previous": "prevSurface",
        "view.toggleSidebar": "toggleSidebar",
        "palette.show": "commandPalette",
        // Go to Tab… became Search Tabs (one tab list); with a tab target it
        // still focuses that tab.
        "palette.goToTab": "tab.search",
        // The link menu's Open Link in New Tab (R123): keybindings and scripts keep working.
        "openLinkInNewTab": "browser.link.openInNewTab",
        // Browser profile placeholders from before browser profiles existed.
        "browserNewProfile": "browserProfile.new",
        "browserRenameProfile": "browserProfile.rename",
        // Rooms became Spaces (Leo, 2026-10-02): keybindings and scripts keep working.
        "browserProfile.clearRoomDefault": "browserProfile.clearSpaceDefault",
        "browserProfile.setRoomDefault": "browserProfile.setSpaceDefault",
        "room.clearColor": "space.clearColor",
        "room.clearIcon": "space.clearIcon",
        "room.clearTheme": "space.clearTheme",
        "room.color.blue": "space.color.blue",
        "room.color.cyan": "space.color.cyan",
        "room.color.green": "space.color.green",
        "room.color.grey": "space.color.grey",
        "room.color.orange": "space.color.orange",
        "room.color.pink": "space.color.pink",
        "room.color.purple": "space.color.purple",
        "room.color.red": "space.color.red",
        "room.color.yellow": "space.color.yellow",
        "room.delete": "space.delete",
        "room.move": "space.move",
        "room.moveLeft": "space.moveLeft",
        "room.moveRight": "space.moveRight",
        "room.new": "space.new",
        "room.newWindow": "space.newWindow",
        "room.newWorkspace": "space.newWorkspace",
        "room.next": "space.next",
        "room.previous": "space.previous",
        "room.rename": "space.rename",
        "room.selectByNumber": "space.selectByNumber",
        "room.setColor": "space.setColor",
        "room.setDefaults": "space.setDefaults",
        "room.setIcon": "space.setIcon",
        "room.setTheme": "space.setTheme",
        "room.switch": "space.switch",
        "sidebar.section.toggleRoomScope": "sidebar.section.toggleSpaceScope",
        "workspace.duplicateToRoom": "workspace.duplicateToSpace",
        "workspace.moveToRoom": "workspace.moveToSpace",
        "workspaceGroup.moveToRoom": "workspaceGroup.moveToSpace",
    ]

    /// Actions whose work makes a browser tab with the keyed
    /// `new-frontend-browser-tab` (`ActionDescriptor.waitsForKeyedCreate`).
    static let keyedCreateActionIDs: Set<ActionID> = [
        "openBrowser", "openBrowser.webkit", "openBrowser.chromium", "newBrowserWorkspace",
        "browser.link.openInNewTab", "browser.image.openInNewTab", "browser.link.openInSplit",
        "browser.link.openInNewWorkspace", "browser.selection.search",
    ]

    /// The catalog's domain groups, in inventory order. `all` concatenates
    /// their descriptors in this order, which menu ranks tie-break on.
    static let groups: [any ActionCatalogGroup.Type] = [
        WindowActionCatalog.self,
        WorkspaceActionCatalog.self,
        WorkspaceVerbActionCatalog.self,
        WorkspaceGroupActionCatalog.self,
        ProfileActionCatalog.self,
        ThemeActionCatalog.self,
        PaneActionCatalog.self,
        TabActionCatalog.self,
        TabIconActionCatalog.self,
        ResourceActionCatalog.self,
        HomeActionCatalog.self,
        HomeMessageActionCatalog.self,
        TabGroupActionCatalog.self,
        ScreenActionCatalog.self,
        ScreenGroupActionCatalog.self,
        TerminalActionCatalog.self,
        BrowserActionCatalog.self,
        BrowserToolbarActionCatalog.self,
        BrowserChromeActionCatalog.self,
        BrowserHitActionCatalog.self,
        ViewerActionCatalog.self,
        FilePageActionCatalog.self,
        PageInfoActionCatalog.self,
        CertificateWarningActionCatalog.self,
        ExtensionActionCatalog.self,
        BrowserProfileActionCatalog.self,
        ProfileMenuActionCatalog.self,
        SidebarActionCatalog.self,
        NotificationActionCatalog.self,
        NotificationSoundActionCatalog.self,
        AgentActionCatalog.self,
        AgentChatMenuActionCatalog.self,
        AgentConfigurationActionCatalog.self,
        AgentTranscriptActionCatalog.self,
        AgentChatIdentifierActionCatalog.self,
        AgentShareActionCatalog.self,
        AgentChatCopyActionCatalog.self,
        AgentChatViewActionCatalog.self,
        AgentSideQuestionActionCatalog.self,
        AgentHarnessActionCatalog.self,
        CloudActionCatalog.self,
        CloudPortActionCatalog.self,
        AccountActionCatalog.self,
        RemoteActionCatalog.self,
        CloudSessionActionCatalog.self,
        MachineIconActionCatalog.self,
        SettingsActionCatalog.self,
        HelpLinkActionCatalog.self,
        DensityActionCatalog.self,
        ChromeStyleActionCatalog.self,
        BackdropActionCatalog.self,
        PaneBackgroundActionCatalog.self,
        HibernationActionCatalog.self,
        AutoArchiveActionCatalog.self,
        LayoutActionCatalog.self,
        HistoryActionCatalog.self,
        StashActionCatalog.self,
        MusicActionCatalog.self,
        VoiceRoomActionCatalog.self,
        ChiefScreenShareActionCatalog.self,
        NowPlayingCardActionCatalog.self,
        BookmarkActionCatalog.self,
        SidebarSectionActionCatalog.self,
        SidebarPriorityActionCatalog.self,
        JoinedMachineActionCatalog.self,
        AppStoreActionCatalog.self,
        AutomationsActionCatalog.self,
        TasksActionCatalog.self,
        PhoneActionCatalog.self,
        FilesPaneActionCatalog.self,
        LinkActionCatalog.self,
        ShareActionCatalog.self,
        ServerActionCatalog.self,
        MarkdownPageActionCatalog.self,
        ListActionCatalog.self,
        PaletteKeyActionCatalog.self,
        ImportActionCatalog.self,
        HangReportsActionCatalog.self,
    ]

    private static func makeAll() -> [ActionDescriptor] {
        var all: [ActionDescriptor] = []
        for group in groups { all += group.descriptors() }
        for index in all.indices where focusActionIDs.contains(all[index].id) { all[index].focuses = true }
        for index in all.indices where keyedCreateActionIDs.contains(all[index].id) { all[index].waitsForKeyedCreate = true }
        return ActionSurfaceCatalog.apply(to: all).withLeaderChords()
    }
}

extension ActionRegistry {
    /// A registry seeded with the full cmux catalog and legacy aliases whose runs are not timed.
    ///
    /// A separate symbol, not a default argument of ``standard(runTiming:)``: objects compiled
    /// before the timing was injected call this one (warm fleet build trees link them).
    public static func standard() -> ActionRegistry {
        standard(runTiming: NoActionRunTiming())
    }

    /// A registry seeded with the full cmux catalog and legacy aliases.
    ///
    /// - Parameter runTiming: Times every run (the App passes ``SignpostActionRunTiming``).
    public static func standard(runTiming: any ActionRunTiming) -> ActionRegistry {
        ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases, runTiming: runTiming)
    }
}
