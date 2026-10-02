import CmuxNextActions
import Testing

/// Catalog completeness against plans/cmux-next/inventory.md section 1.
@Suite struct ActionCatalogTests {
    /// Every `KeyboardShortcutSettings.Action` ID named in the inventory. Users
    /// store these in `cmux.json`, so each must exist with the same spelling.
    static let keyboardShortcutIDs: [ActionID] = [
        // Window / app
        "openSettings", "newWindow", "closeWindow", "toggleFullScreen", "quit", "showHideAllWindows",
        "globalSearch", "commandPalette", "commandPaletteNext", "commandPalettePrevious", "goToWorkspace",
        "focusHistoryBack", "focusHistoryForward", "focusHistoryLast",
        // Workspace
        "newTab", "newBrowserWorkspace", "openFolder", "reopenPreviousSession", "reopenClosedWorkspace",
        "nextSidebarTab", "prevSidebarTab", "nextSidebarTabInGroup", "prevSidebarTabInGroup",
        "moveWorkspaceUp", "moveWorkspaceDown", "selectWorkspaceByNumber", "renameWorkspace",
        "editWorkspaceDescription", "markWorkspaceDone", "cycleWorkspaceStatus", "toggleChecklistItemComplete",
        "closeWorkspace", "newWorkspaceGroup", "groupSelectedWorkspaces", "toggleFocusedWorkspaceGroupCollapsed",
        "saveLayoutTemplate",
        // Pane
        "splitRight", "splitDown", "newPaneAutoLayout", "toggleSplitZoom", "equalizeSplits",
        "resizePaneLeft", "resizePaneRight", "resizePaneUp", "resizePaneDown",
        "focusLeft", "focusRight", "focusUp", "focusDown", "focusPreviousPane", "focusNextPane", "triggerFlash",
        "increaseWorkspaceTerminalFontSize", "decreaseWorkspaceTerminalFontSize", "resetWorkspaceTerminalFontSize",
        "toggleCanvasLayout", "canvasOverview", "canvasTidy", "canvasRevealFocusedPane",
        "canvasZoomIn", "canvasZoomOut", "canvasZoomReset",
        "simulatorHome", "simulatorRotateLeft", "simulatorRotateRight", "simulatorToggleAppearance",
        "simulatorToggleSoftwareKeyboard",
        // Tab
        "newSurface", "openBrowser", "closeTab", "closeOtherTabsInPane", "renameTab", "nextSurface", "prevSurface",
        "moveSurfaceLeft", "moveSurfaceRight", "moveSurfaceToPreviousPane", "moveSurfaceToNextPane",
        "moveSurfaceToPaneLeft", "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPaneDown",
        "selectSurfaceByNumber", "reopenClosedBrowserPanel",
        // Terminal
        "toggleTerminalCopyMode", "focusTextBoxInput", "cycleTextBoxSubmitAction", "attachTextBoxFile",
        "sendCtrlFToTerminal", "pasteLastScreenshot", "clearScreenKeepScrollback",
        "find", "findInDirectory", "findNext", "findPrevious", "hideFind", "useSelectionForFind",
        // Browser / viewers
        "browserBack", "browserForward", "browserReload", "browserHardReload", "focusBrowserAddressBar",
        "browserZoomIn", "browserZoomOut", "browserZoomReset", "markdownZoomIn", "markdownZoomOut", "markdownZoomReset",
        "toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "toggleBrowserFocusMode",
        "toggleBrowserDesignMode", "toggleReactGrab", "splitBrowserRight", "splitBrowserDown",
        "saveFilePreview", "toggleFileEditorWordWrap", "openDiffViewer",
        // Sidebar
        "toggleSidebar", "toggleRightSidebar", "focusRightSidebar",
        "switchRightSidebarToFiles", "switchRightSidebarToFind", "switchRightSidebarToSessions",
        "switchRightSidebarToFeed", "switchRightSidebarToDock", "switchRightSidebarToMachines",
        "fileExplorerOpenSelection", "fileExplorerOpenSelectionFinderAlias",
        // Notifications
        "showNotifications", "jumpToUnread", "toggleUnread", "markOldestUnreadAndJumpNext",
        "markAllNotificationsRead", "clearAllNotifications",
        // Cloud / account
        "newCloudWorkspace", "newCloudMachine", "openTeamPicker",
        // Settings / help
        "reloadConfiguration", "sendFeedback",
    ]

    /// Rows per inventory domain after splitting compound rows ("Focus
    /// Left/Right/Up/Down") into one action each. Dynamic families (workspace
    /// switcher rows, per-app open targets, per-setting toggles) are served by
    /// palette providers and appear here once as their parent list action.
    /// Workspace and tab include the group families (architecture.md section 7).
    /// Pane, tab, and terminal also count the cmux-next rows in
    /// `ActionCatalog+Layout.swift` (19 pane/column, 6 tab, 10 terminal).
    /// Screen counts the screen and screen group families
    /// (`ActionCatalog+Screens.swift`, `ActionCatalog+ScreenGroups.swift`).
    /// Settings counts the pane border, padding and corner toggles and the
    /// two titlebar styles, the focus ring and border width toggles and the
    /// border color reset, and Make cmux the Default Browser. Window
    /// counts Minimize (no inventory row; used by idle and visibility checks).
    static let expectedCounts: [ActionCategory: Int] = [
        .window: 32, // + Quit and Keep Sessions, Quit and End Sessions (Keep Layout), Quit and End Everything; + 5 history (history.md)
        .workspace: 139, // 80 + 29 room actions (plans/cmux-next/data-model.md 7) + showResources + 25 workspace verbs + 4 room/workspace theme actions
        .pane: 71, // + Move Pane to New Workspace, Undo Layout Change; + 4 sticky column actions (sticky-column.md)
        .screen: 62,
        .tab: 77, // + Search Tabs (tab-search.md), New Tab Page
        .terminal: 35, // + Set / Reset Terminal Theme
        .browser: 111, // 78 - 2 profile placeholders + 18 browser profile actions (data-model.md 5) + Show History (Cmd-Y in a page) + 15 bookmark actions + Import Passwords from CSV
        .sidebar: 56, // + 26 sidebar section actions (sidebar-sections.md 6)
        .notifications: 18,
        .agents: 21, // + Resume Agent Session, Toggle Dictation, Open Agent Activity, Search Agent Chats, Continue In
        .cloud: 31, // + accounts.show, refresh, reauthenticate, connect, remove; + lifecycle and snapshot actions
        .remote: 7, // SSH machines (Connect to Machine…), Open Terminal on Machine Here
        .settings: 55, // + Toggle Column Scroll Bar, + Onboarding Gallery (DEBUG only), + Open Debug Settings (DEV and NIGHTLY only), + App Store, Installed Apps, Hide App, Unhide App, + Customize Appearance
    ]

    @Test func everyKeyboardShortcutIDExists() {
        let ids = Set(ActionCatalog.all.map(\.id))
        let missing = Self.keyboardShortcutIDs.filter { !ids.contains($0) }
        #expect(missing.isEmpty, "missing: \(missing)")
    }

    @Test func countsByDomainMatchInventory() {
        var counts: [ActionCategory: Int] = [:]
        for descriptor in ActionCatalog.all { counts[descriptor.category, default: 0] += 1 }
        for category in ActionCategory.allCases where category != .other {
            #expect(counts[category] == Self.expectedCounts[category], "\(category)")
        }
        // Inventory estimate is about 290 merged rows; splitting compound
        // rows lands above it.
        #expect(ActionCatalog.all.count >= 290)
    }

    @Test func idsAreUniqueAndTitlesPresent() {
        let ids = ActionCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for descriptor in ActionCatalog.all {
            #expect(!descriptor.title.isEmpty, "\(descriptor.id)")
            #expect(!descriptor.symbol.isEmpty, "\(descriptor.id)")
            #expect(!descriptor.surfaces.isEmpty, "\(descriptor.id)")
        }
    }

    @Test func standardCatalogHasNoUnresolvableShortcutConflicts() {
        let registry = ActionRegistry.standard()
        #expect(registry.shortcutConflicts().isEmpty, "\(registry.shortcutConflicts())")
    }

    @Test func legacyAliasesPointAtCatalogIDs() {
        let ids = Set(ActionCatalog.all.map(\.id))
        for (legacy, canonical) in ActionCatalog.legacyAliases {
            #expect(ids.contains(canonical), "\(legacy) -> \(canonical)")
        }
    }
}
