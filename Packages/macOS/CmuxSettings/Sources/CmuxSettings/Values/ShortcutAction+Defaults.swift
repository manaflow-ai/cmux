import Foundation

extension ShortcutAction {
    /// The factory-default shortcut for this action, including two-stroke chords.
    public var defaultShortcut: StoredShortcut? {
        switch self {
        case .diffViewerScrollToTop:
            return StoredShortcut(
                first: ShortcutStroke(key: "g"),
                second: ShortcutStroke(key: "g")
            )
        default:
            return defaultStroke.map { StoredShortcut(first: $0) }
        }
    }

    /// The factory-default ``ShortcutStroke`` for this action.
    ///
    /// Mirrors the table in
    /// `Sources/KeyboardShortcutSettings.swift` so the package's
    /// settings UI can show "(default: ⌘N)" instead of "(default)"
    /// next to unbound rows, and so the Reset action in the Settings
    /// UI can restore a row by writing the default stroke through
    /// the JSON store.
    public var defaultStroke: ShortcutStroke? {
        switch self {
        case .openSettings: return ShortcutStroke(key: ",", command: true)
        case .reloadConfiguration: return ShortcutStroke(key: ",", command: true, shift: true)
        case .showHideAllWindows: return ShortcutStroke(key: ".", command: true, option: true, control: true)
        case .globalSearch: return ShortcutStroke(key: "f", command: true, option: true)
        case .newWindow: return ShortcutStroke(key: "n", command: true, shift: true)
        case .closeWindow: return ShortcutStroke(key: "w", command: true, control: true)
        case .toggleFullScreen: return ShortcutStroke(key: "f", command: true, control: true)
        case .quit: return ShortcutStroke(key: "q", command: true)
        case .toggleSidebar: return ShortcutStroke(key: "b", command: true)
        case .newTab: return ShortcutStroke(key: "n", command: true)
        case .newBrowserWorkspace: return ShortcutStroke(key: "n", command: true, option: true)
        case .openFolder: return ShortcutStroke(key: "o", command: true)
        case .reopenPreviousSession: return ShortcutStroke(key: "o", command: true, shift: true)
        case .goToWorkspace: return ShortcutStroke(key: "p", command: true)
        case .commandPalette: return ShortcutStroke(key: "p", command: true, shift: true)
        case .commandPaletteNext: return ShortcutStroke(key: "n", control: true)
        case .commandPalettePrevious: return ShortcutStroke(key: "p", control: true)
        case .sendFeedback: return nil
        case .showNotifications: return ShortcutStroke(key: "i", command: true)
        case .jumpToUnread: return ShortcutStroke(key: "u", command: true, shift: true)
        case .toggleUnread: return ShortcutStroke(key: "u", command: true, option: true)
        case .markOldestUnreadAndJumpNext: return ShortcutStroke(key: "u", command: true, control: true)
        case .focusRightSidebar: return ShortcutStroke(key: "e", command: true, shift: true)
        case .switchRightSidebarToFiles: return ShortcutStroke(key: "1", control: true)
        case .switchRightSidebarToFind: return ShortcutStroke(key: "2", control: true)
        case .switchRightSidebarToSessions: return ShortcutStroke(key: "3", control: true)
        case .switchRightSidebarToFeed: return ShortcutStroke(key: "4", control: true)
        case .switchRightSidebarToDock: return ShortcutStroke(key: "5", control: true)
        case .triggerFlash: return ShortcutStroke(key: "h", command: true, shift: true)
        case .nextSidebarTab: return ShortcutStroke(key: "]", command: true, control: true)
        case .prevSidebarTab: return ShortcutStroke(key: "[", command: true, control: true)
        case .focusHistoryBack: return ShortcutStroke(key: "[", command: true)
        case .focusHistoryForward: return ShortcutStroke(key: "]", command: true)
        case .renameTab: return ShortcutStroke(key: "r", command: true)
        case .renameWorkspace: return ShortcutStroke(key: "r", command: true, shift: true)
        case .editWorkspaceDescription: return ShortcutStroke(key: "e", command: true, option: true)
        case .closeTab: return ShortcutStroke(key: "w", command: true)
        case .closeOtherTabsInPane: return ShortcutStroke(key: "t", command: true, option: true)
        case .closeWorkspace: return ShortcutStroke(key: "w", command: true, shift: true)
        case .groupSelectedWorkspaces: return ShortcutStroke(key: "g", command: true, shift: true)
        case .toggleFocusedWorkspaceGroupCollapsed: return ShortcutStroke(key: ".", command: true, control: true)
        case .reopenClosedBrowserPanel: return ShortcutStroke(key: "t", command: true, shift: true)
        case .focusLeft: return ShortcutStroke(key: "←", command: true, option: true)
        case .focusRight: return ShortcutStroke(key: "→", command: true, option: true)
        case .focusUp: return ShortcutStroke(key: "↑", command: true, option: true)
        case .focusDown: return ShortcutStroke(key: "↓", command: true, option: true)
        case .splitRight: return ShortcutStroke(key: "d", command: true)
        case .splitDown: return ShortcutStroke(key: "d", command: true, shift: true)
        case .toggleSplitZoom: return ShortcutStroke(key: "\r", command: true, shift: true)
        case .equalizeSplits: return ShortcutStroke(key: "=", command: true, control: true)
        case .splitBrowserRight: return ShortcutStroke(key: "d", command: true, option: true)
        case .splitBrowserDown: return ShortcutStroke(key: "d", command: true, shift: true, option: true)
        case .toggleCanvasLayout: return ShortcutStroke(key: "c", command: true, control: true)
        case .canvasRevealFocusedPane: return ShortcutStroke(key: "r", command: true, control: true)
        case .canvasOverview: return ShortcutStroke(key: "o", command: true, control: true)
        case .canvasZoomIn: return ShortcutStroke(key: "=", command: true, option: true)
        case .canvasZoomOut: return ShortcutStroke(key: "-", command: true, option: true)
        case .canvasZoomReset: return ShortcutStroke(key: "0", command: true, option: true)
        case .canvasTidy: return ShortcutStroke(key: "t", command: true, control: true)
        case .canvasAlignLeft, .canvasAlignRight, .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally, .canvasDistributeVertically:
            // Unbound by default; reachable through the command palette and
            // the canvas.* socket verbs.
            return nil
        case .nextSurface: return ShortcutStroke(key: "]", command: true, shift: true)
        case .prevSurface: return ShortcutStroke(key: "[", command: true, shift: true)
        case .selectSurfaceByNumber: return ShortcutStroke(key: "1", control: true)
        case .selectWorkspaceByNumber: return ShortcutStroke(key: "1", command: true)
        case .newSurface: return ShortcutStroke(key: "t", command: true)
        case .toggleTerminalCopyMode: return ShortcutStroke(key: "m", command: true, shift: true)
        case .focusTextBoxInput: return ShortcutStroke(key: "a", command: true, shift: true)
        case .attachTextBoxFile: return ShortcutStroke(key: "a", command: true, shift: true, option: true)
        case .sendCtrlFToTerminal: return nil
        case .clearScreenKeepScrollback: return ShortcutStroke(key: "k", command: true, shift: true)
        case .toggleRightSidebar: return ShortcutStroke(key: "b", command: true, option: true)
        case .fileExplorerOpenSelection: return ShortcutStroke(key: "\r")
        case .fileExplorerOpenSelectionFinderAlias: return ShortcutStroke(key: "↓", command: true)
        case .openDiffViewer: return ShortcutStroke(key: "d", command: true, shift: true, control: true)
        case .saveFilePreview: return ShortcutStroke(key: "s", command: true)
        case .openBrowser: return ShortcutStroke(key: "l", command: true, shift: true)
        case .focusBrowserAddressBar: return ShortcutStroke(key: "l", command: true)
        case .browserBack: return ShortcutStroke(key: "[", command: true)
        case .browserForward: return ShortcutStroke(key: "]", command: true)
        case .browserReload: return ShortcutStroke(key: "r", command: true)
        case .browserHardReload: return ShortcutStroke(key: "r", command: true, shift: true)
        case .browserZoomIn: return ShortcutStroke(key: "=", command: true)
        case .browserZoomOut: return ShortcutStroke(key: "-", command: true)
        case .browserZoomReset: return ShortcutStroke(key: "0", command: true)
        case .markdownZoomIn: return ShortcutStroke(key: "=", command: true)
        case .markdownZoomOut: return ShortcutStroke(key: "-", command: true)
        case .markdownZoomReset: return ShortcutStroke(key: "0", command: true)
        case .find: return ShortcutStroke(key: "f", command: true)
        case .findInDirectory: return ShortcutStroke(key: "f", command: true, shift: true)
        case .findNext: return ShortcutStroke(key: "g", command: true)
        case .findPrevious: return ShortcutStroke(key: "g", command: true, option: true)
        case .hideFind: return ShortcutStroke(key: "f", command: true, shift: true, option: true)
        case .useSelectionForFind: return ShortcutStroke(key: "e", command: true)
        case .toggleBrowserDeveloperTools: return ShortcutStroke(key: "i", command: true, option: true)
        case .showBrowserJavaScriptConsole: return ShortcutStroke(key: "c", command: true, option: true)
        case .toggleBrowserFocusMode: return ShortcutStroke(key: "\r", command: true, option: true)
        case .toggleReactGrab: return ShortcutStroke(key: "g", command: true, shift: true)
        case .diffViewerScrollDown: return ShortcutStroke(key: "j")
        case .diffViewerScrollUp: return ShortcutStroke(key: "k")
        case .diffViewerScrollToBottom: return ShortcutStroke(key: "g", shift: true)
        case .diffViewerScrollToTop: return nil
        case .diffViewerOpenFileSearch: return ShortcutStroke(key: "/")
        }
    }
}
