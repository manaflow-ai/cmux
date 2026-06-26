import Foundation

/// The stable, user-customisable shortcut actions cmux exposes.
///
/// Each case is a one-line identifier that maps to one user-facing
/// behavior. The set is intentionally flat (rather than nested by
/// category) so the JSON config representation stays readable
/// (`"shortcuts.bindings": { "openSettings": "cmd+,", ... }`).
///
/// Display names + group categorization are metadata derived from the
/// enum case in extensions below; the raw value is the stable
/// identifier persisted in cmux.json.
public enum ShortcutAction: String, CaseIterable, Sendable, Hashable, SettingCodable {
    // MARK: App
    case openSettings
    case reloadConfiguration
    case showHideAllWindows
    case globalSearch
    case newWindow
    case closeWindow
    case toggleFullScreen
    case quit

    // MARK: Workspace
    case toggleSidebar
    case newTab
    case newBrowserWorkspace
    case openFolder
    case reopenPreviousSession
    case goToWorkspace
    case commandPalette
    case commandPaletteNext
    case commandPalettePrevious
    case sendFeedback
    case showNotifications
    case jumpToUnread
    case toggleUnread
    case markOldestUnreadAndJumpNext
    case focusRightSidebar
    case switchRightSidebarToFiles
    case switchRightSidebarToFind
    case switchRightSidebarToSessions
    case switchRightSidebarToFeed
    case switchRightSidebarToDock
    case triggerFlash

    // MARK: Navigation
    case nextSurface
    case prevSurface
    case selectSurfaceByNumber
    case nextSidebarTab
    case prevSidebarTab
    case focusHistoryBack
    case focusHistoryForward
    case selectWorkspaceByNumber
    case renameTab
    case renameWorkspace
    case editWorkspaceDescription
    case closeTab
    case closeOtherTabsInPane
    case closeWorkspace
    /// Groups the selected workspaces in the workspace list.
    case groupSelectedWorkspaces
    /// Toggles collapse for the group containing the focused workspace.
    case toggleFocusedWorkspaceGroupCollapsed
    case reopenClosedBrowserPanel
    case newSurface
    case toggleTerminalCopyMode
    case focusTextBoxInput
    case attachTextBoxFile
    /// Sends a Ctrl-F keystroke through to the focused terminal.
    case sendCtrlFToTerminal
    /// Clears the focused terminal's visible screen while preserving scrollback.
    case clearScreenKeepScrollback

    // MARK: Panes
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case splitRight
    case splitDown
    case toggleSplitZoom
    case equalizeSplits
    case splitBrowserRight
    case splitBrowserDown
    case toggleRightSidebar = "toggleFileExplorer"
    /// Opens the selected File Explorer item from File Explorer focus.
    case fileExplorerOpenSelection
    /// Mirrors Finder's Command-Down open-selection shortcut from File Explorer focus.
    case fileExplorerOpenSelectionFinderAlias

    // MARK: Canvas
    case toggleCanvasLayout
    case canvasRevealFocusedPane
    case canvasOverview
    case canvasZoomIn
    case canvasZoomOut
    case canvasZoomReset
    case canvasTidy
    case canvasAlignLeft
    case canvasAlignRight
    case canvasAlignTop
    case canvasAlignBottom
    case canvasEqualizeWidths
    case canvasEqualizeHeights
    case canvasDistributeHorizontally
    case canvasDistributeVertically

    // MARK: Browser & Find
    case openDiffViewer
    case saveFilePreview
    case openBrowser
    case focusBrowserAddressBar
    case browserBack
    case browserForward
    case browserReload
    /// Hard refreshes the focused browser pane, bypassing WebKit's cache.
    case browserHardReload
    case browserZoomIn
    case browserZoomOut
    case browserZoomReset
    case markdownZoomIn
    case markdownZoomOut
    case markdownZoomReset
    case find
    case findInDirectory
    case findNext
    case findPrevious
    case hideFind
    case useSelectionForFind
    case toggleBrowserDeveloperTools
    case showBrowserJavaScriptConsole
    case toggleBrowserFocusMode
    case toggleReactGrab
    /// Scrolls the focused diff viewer down one step.
    case diffViewerScrollDown
    /// Scrolls the focused diff viewer up one step.
    case diffViewerScrollUp
    /// Scrolls the focused diff viewer to the bottom.
    case diffViewerScrollToBottom
    /// Scrolls the focused diff viewer to the top.
    case diffViewerScrollToTop
    /// Opens file search inside the focused diff viewer.
    case diffViewerOpenFileSearch
}

extension ShortcutAction {
    /// Logical grouping used for sectioning the shortcuts pane.
    public enum Group: String, CaseIterable, Sendable, Hashable {
        case app
        case workspace
        case navigation
        case panes
        case browser

        public var title: String {
            switch self {
            case .app: return "App"
            case .workspace: return "Workspace"
            case .navigation: return "Navigation"
            case .panes: return "Panes"
            case .browser: return "Browser & Find"
            }
        }
    }

    /// Which group this action belongs to in the settings pane.
    public var group: Group {
        switch self {
        case .openSettings, .reloadConfiguration, .showHideAllWindows, .globalSearch,
             .newWindow, .closeWindow, .toggleFullScreen, .quit:
            return .app
        case .toggleSidebar, .newTab, .newBrowserWorkspace, .openFolder, .reopenPreviousSession, .goToWorkspace,
             .commandPalette, .commandPaletteNext, .commandPalettePrevious, .sendFeedback,
             .showNotifications, .jumpToUnread, .toggleUnread, .markOldestUnreadAndJumpNext,
             .focusRightSidebar, .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed,
             .switchRightSidebarToDock, .triggerFlash:
            return .workspace
        case .nextSurface, .prevSurface, .selectSurfaceByNumber, .nextSidebarTab,
             .prevSidebarTab, .focusHistoryBack, .focusHistoryForward,
             .selectWorkspaceByNumber, .renameTab, .renameWorkspace,
             .editWorkspaceDescription, .closeTab, .closeOtherTabsInPane, .closeWorkspace,
             .groupSelectedWorkspaces, .toggleFocusedWorkspaceGroupCollapsed,
             .reopenClosedBrowserPanel, .newSurface, .toggleTerminalCopyMode,
             .focusTextBoxInput, .attachTextBoxFile, .sendCtrlFToTerminal,
             .clearScreenKeepScrollback:
            return .navigation
        case .focusLeft, .focusRight, .focusUp, .focusDown, .splitRight, .splitDown,
             .toggleSplitZoom, .equalizeSplits, .splitBrowserRight, .splitBrowserDown,
             .toggleRightSidebar, .fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias,
             .toggleCanvasLayout, .canvasRevealFocusedPane, .canvasOverview,
             .canvasZoomIn, .canvasZoomOut, .canvasZoomReset, .canvasTidy,
             .canvasAlignLeft, .canvasAlignRight, .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally, .canvasDistributeVertically:
            return .panes
        case .openDiffViewer, .saveFilePreview, .openBrowser, .focusBrowserAddressBar, .browserBack,
             .browserForward, .browserReload, .browserHardReload, .browserZoomIn, .browserZoomOut,
             .browserZoomReset, .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .find, .findInDirectory, .findNext, .findPrevious,
             .hideFind, .useSelectionForFind, .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole, .toggleBrowserFocusMode, .toggleReactGrab,
             .diffViewerScrollDown, .diffViewerScrollUp, .diffViewerScrollToBottom,
             .diffViewerScrollToTop, .diffViewerOpenFileSearch:
            return .browser
        }
    }

    /// Whether this action binds the whole `1…9` digit range through a
    /// single stored placeholder.
    ///
    /// ``selectSurfaceByNumber`` and ``selectWorkspaceByNumber`` are special:
    /// one binding (with the digit normalized to `"1"`) stands in for the
    /// entire `⌘1`–`⌘9` / `⌃1`–`⌃9` family. UI that displays the binding
    /// should render it as `⌘1…9` or `⌃1…9` (the range) rather than the
    /// literal single-digit shortcut, and recording any digit `1`–`9`
    /// rebinds the whole range. All other actions match a single concrete
    /// keystroke.
    public var usesNumberedDigitMatching: Bool {
        switch self {
        case .selectSurfaceByNumber, .selectWorkspaceByNumber:
            return true
        default:
            return false
        }
    }

    /// Whether the recorder may accept a shortcut whose first stroke has no modifier.
    ///
    /// Most cmux-owned shortcuts require a modifier on the first stroke to avoid
    /// accidentally stealing plain typing from terminals, editors, and browser
    /// content. Focus-scoped content shortcuts, such as diff-viewer navigation and
    /// file-explorer open, can be rebound to bare first strokes.
    public var allowsBareFirstStroke: Bool {
        switch self {
        case .diffViewerScrollDown,
             .diffViewerScrollUp,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias:
            return true
        default:
            return false
        }
    }

    /// Whether this action supports a two-stroke shortcut chord.
    public var allowsChordShortcut: Bool {
        self != .fileExplorerOpenSelection && self != .fileExplorerOpenSelectionFinderAlias
    }

    /// The action's built-in focus context expressed as a ``ShortcutWhenClause``,
    /// used when no `shortcuts.when` override applies.
    ///
    /// Mirrors the app target's `KeyboardShortcutSettings.Action.shortcutContext`
    /// default-context mapping so the Settings UI's conflict detection evaluates
    /// the same effective context the runtime does. A drift test asserts the two
    /// mappings agree for every shared action.
    public var defaultFocusWhenClause: ShortcutWhenClause {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock:
            return .atom(.sidebarFocus)
        case .fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias:
            return .atom(.sidebarFocus)
        case .renameTab, .renameWorkspace:
            return .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        case .sendCtrlFToTerminal, .clearScreenKeepScrollback:
            return .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        case .browserBack, .browserForward, .browserReload, .browserHardReload,
             .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole,
             .browserZoomIn, .browserZoomOut, .browserZoomReset, .toggleBrowserFocusMode,
             .diffViewerScrollDown, .diffViewerScrollUp, .diffViewerScrollToBottom,
             .diffViewerScrollToTop, .diffViewerOpenFileSearch:
            return .atom(.browserFocus)
        case .markdownZoomIn, .markdownZoomOut, .markdownZoomReset:
            return .atom(.markdownFocus)
        case .canvasZoomReset:
            return .and(
                .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue),
                .and(.not(.atom(.browserFocus)), .not(.atom(.markdownFocus)))
            )
        case .canvasRevealFocusedPane, .canvasOverview,
             .canvasZoomIn, .canvasZoomOut, .canvasTidy,
             .canvasAlignLeft, .canvasAlignRight, .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally, .canvasDistributeVertically:
            return .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue)
        default:
            return .always
        }
    }

    /// Whether the app's key router consumes this action *before* general
    /// configured-shortcut matching whenever its context holds.
    ///
    /// The right-sidebar mode shortcuts are pre-routed: while the sidebar is
    /// focused they win their keystroke outright, and every other binding on the
    /// same stroke keeps firing outside that context. Conflict detection
    /// (``ShortcutWhenClause/bindingsCollide(_:lhsHasPriority:_:rhsHasPriority:)``)
    /// uses this to accept such priority-resolved pairs — e.g. the factory
    /// default Select Workspace `⌃1…9` alongside the sidebar's `⌃1…5` — instead of
    /// rejecting them as colliding. Mirrors the app target's routing order in
    /// `handleCustomShortcut`; a drift test asserts the two stay aligned.
    public var hasPriorityShortcutRouting: Bool {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock:
            return true
        default:
            return false
        }
    }

    /// User-facing display name shown in the Settings UI.
    public var displayName: String {
        switch self {
        case .openSettings: return "Settings…"
        case .reloadConfiguration: return "Reload Configuration"
        case .showHideAllWindows: return "Show/Hide All Windows"
        case .globalSearch: return "Global Search"
        case .newWindow: return "New Window"
        case .closeWindow: return "Close Window"
        case .toggleFullScreen: return "Toggle Full Screen"
        case .quit: return "Quit cmux"
        case .toggleSidebar: return "Toggle Left Sidebar"
        case .newTab: return "New Workspace"
        case .newBrowserWorkspace:
            return String(localized: "shortcut.newBrowserWorkspace.label", defaultValue: "New Browser Workspace")
        case .openFolder: return "Open Folder"
        case .reopenPreviousSession: return "Restore Previous App Launch"
        case .goToWorkspace: return "Go to Workspace…"
        case .commandPalette: return "Command Palette…"
        case .commandPaletteNext: return "Command Palette: Next"
        case .commandPalettePrevious: return "Command Palette: Previous"
        case .sendFeedback: return "Send Feedback"
        case .showNotifications: return "Show Notifications"
        case .jumpToUnread: return "Jump to Latest Unread"
        case .toggleUnread: return "Toggle Unread"
        case .markOldestUnreadAndJumpNext: return "Mark as Oldest Unread and Jump to Next Latest Unread"
        case .focusRightSidebar: return "Toggle Right Sidebar Focus"
        case .switchRightSidebarToFiles: return "Show Sidebar Files"
        case .switchRightSidebarToFind: return "Show Sidebar Find"
        case .switchRightSidebarToSessions: return "Show Sidebar Vault"
        case .switchRightSidebarToFeed: return "Show Sidebar Feed"
        case .switchRightSidebarToDock: return "Show Sidebar Dock"
        case .triggerFlash: return "Flash Focused Panel"
        case .nextSurface: return "Next Surface"
        case .prevSurface: return "Previous Surface"
        case .selectSurfaceByNumber: return "Select Surface 1…9"
        case .nextSidebarTab: return "Next Workspace"
        case .prevSidebarTab: return "Previous Workspace"
        case .focusHistoryBack: return "Focus Back"
        case .focusHistoryForward: return "Focus Forward"
        case .selectWorkspaceByNumber: return "Select Workspace 1…9"
        case .renameTab: return "Rename Tab"
        case .renameWorkspace: return "Rename Workspace"
        case .editWorkspaceDescription: return "Edit Workspace Description"
        case .closeTab: return "Close Tab"
        case .closeOtherTabsInPane: return "Close Other Tabs in Pane"
        case .closeWorkspace: return "Close Workspace"
        case .groupSelectedWorkspaces:
            return String(localized: "shortcut.groupSelectedWorkspaces.label", defaultValue: "Group Selected Workspaces")
        case .toggleFocusedWorkspaceGroupCollapsed:
            return String(localized: "shortcut.toggleFocusedWorkspaceGroupCollapsed.label", defaultValue: "Toggle Focused Workspace's Group Collapse")
        case .reopenClosedBrowserPanel: return "Reopen Last Closed"
        case .newSurface: return "New Surface"
        case .toggleTerminalCopyMode: return "Toggle Terminal Copy Mode"
        case .focusTextBoxInput: return "Focus TextBox Input"
        case .attachTextBoxFile: return "Attach File to TextBox Input"
        case .sendCtrlFToTerminal:
            return String(localized: "shortcut.sendCtrlFToTerminal.label", defaultValue: "Send Ctrl-F to Terminal")
        case .clearScreenKeepScrollback:
            return String(localized: "shortcut.clearScreenKeepScrollback.label", defaultValue: "Clear Screen (Keep Scrollback)")
        case .focusLeft: return "Focus Pane Left"
        case .focusRight: return "Focus Pane Right"
        case .focusUp: return "Focus Pane Up"
        case .focusDown: return "Focus Pane Down"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .toggleSplitZoom: return "Toggle Pane Zoom"
        case .equalizeSplits: return "Equalize Splits"
        case .splitBrowserRight: return "Split Browser Right"
        case .splitBrowserDown: return "Split Browser Down"
        case .toggleRightSidebar: return "Toggle Right Sidebar"
        case .fileExplorerOpenSelection:
            return String(localized: "shortcut.fileExplorerOpenSelection.label", defaultValue: "File Explorer: Open Selection")
        case .fileExplorerOpenSelectionFinderAlias:
            return String(localized: "shortcut.fileExplorerOpenSelectionFinderAlias.label", defaultValue: "File Explorer: Open Selection (Finder Alias)")
        case .toggleCanvasLayout:
            return String(localized: "shortcut.toggleCanvasLayout.label", defaultValue: "Toggle Canvas Layout")
        case .canvasRevealFocusedPane:
            return String(localized: "shortcut.canvasRevealFocusedPane.label", defaultValue: "Canvas: Reveal Focused Pane")
        case .canvasOverview:
            return String(localized: "shortcut.canvasOverview.label", defaultValue: "Canvas: Toggle Overview")
        case .canvasZoomIn:
            return String(localized: "shortcut.canvasZoomIn.label", defaultValue: "Canvas: Zoom In")
        case .canvasZoomOut:
            return String(localized: "shortcut.canvasZoomOut.label", defaultValue: "Canvas: Zoom Out")
        case .canvasZoomReset:
            return String(localized: "shortcut.canvasZoomReset.label", defaultValue: "Canvas: Actual Size")
        case .canvasTidy:
            return String(localized: "shortcut.canvasTidy.label", defaultValue: "Canvas: Tidy Panes")
        case .canvasAlignLeft:
            return String(localized: "shortcut.canvasAlignLeft.label", defaultValue: "Canvas: Align Left Edges")
        case .canvasAlignRight:
            return String(localized: "shortcut.canvasAlignRight.label", defaultValue: "Canvas: Align Right Edges")
        case .canvasAlignTop:
            return String(localized: "shortcut.canvasAlignTop.label", defaultValue: "Canvas: Align Top Edges")
        case .canvasAlignBottom:
            return String(localized: "shortcut.canvasAlignBottom.label", defaultValue: "Canvas: Align Bottom Edges")
        case .canvasEqualizeWidths:
            return String(localized: "shortcut.canvasEqualizeWidths.label", defaultValue: "Canvas: Equalize Widths")
        case .canvasEqualizeHeights:
            return String(localized: "shortcut.canvasEqualizeHeights.label", defaultValue: "Canvas: Equalize Heights")
        case .canvasDistributeHorizontally:
            return String(localized: "shortcut.canvasDistributeHorizontally.label", defaultValue: "Canvas: Distribute Horizontally")
        case .canvasDistributeVertically:
            return String(localized: "shortcut.canvasDistributeVertically.label", defaultValue: "Canvas: Distribute Vertically")
        case .openDiffViewer: return "Open Diff Viewer"
        case .saveFilePreview: return "Save File Preview"
        case .openBrowser: return "Open Browser"
        case .focusBrowserAddressBar: return "Focus Address Bar"
        case .browserBack: return "Back"
        case .browserForward: return "Forward"
        case .browserReload: return "Reload Page"
        case .browserHardReload: return String(localized: "menu.view.hardRefresh", defaultValue: "Hard Refresh")
        case .browserZoomIn: return "Zoom In"
        case .browserZoomOut: return "Zoom Out"
        case .browserZoomReset: return "Actual Size"
        case .markdownZoomIn: return "Markdown Viewer: Zoom In"
        case .markdownZoomOut: return "Markdown Viewer: Zoom Out"
        case .markdownZoomReset: return "Markdown Viewer: Actual Size"
        case .find: return "Find…"
        case .findInDirectory: return "Find in Directory…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .hideFind: return "Hide Find Bar"
        case .useSelectionForFind: return "Use Selection for Find"
        case .toggleBrowserDeveloperTools: return "Toggle Browser Developer Tools"
        case .showBrowserJavaScriptConsole: return "Show Browser JavaScript Console"
        case .toggleBrowserFocusMode: return "Enter Browser Focus Mode"
        case .toggleReactGrab: return "Toggle React Grab"
        case .diffViewerScrollDown:
            return String(localized: "shortcut.diffViewerScrollDown.label", defaultValue: "Diff Viewer: Scroll Down")
        case .diffViewerScrollUp:
            return String(localized: "shortcut.diffViewerScrollUp.label", defaultValue: "Diff Viewer: Scroll Up")
        case .diffViewerScrollToBottom:
            return String(localized: "shortcut.diffViewerScrollToBottom.label", defaultValue: "Diff Viewer: Scroll to Bottom")
        case .diffViewerScrollToTop:
            return String(localized: "shortcut.diffViewerScrollToTop.label", defaultValue: "Diff Viewer: Scroll to Top")
        case .diffViewerOpenFileSearch:
            return String(localized: "shortcut.diffViewerOpenFileSearch.label", defaultValue: "Diff Viewer: Open File Search")
        }
    }
}
