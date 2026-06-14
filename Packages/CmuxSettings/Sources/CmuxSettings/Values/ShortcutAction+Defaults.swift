import Foundation

extension ShortcutAction {
    /// The factory-default shortcut for this action, including two-stroke chords.
    ///
    /// Mirrors the table in `Sources/KeyboardShortcutSettings.swift` so the package's
    /// settings UI can show built-in bindings next to unbound rows and reset through
    /// the JSON store without losing chorded defaults.
    public var defaultShortcut: StoredShortcut? {
        switch self {
        case .openSettings: return Self.shortcut(key: ",", command: true)
        case .reloadConfiguration: return Self.shortcut(key: ",", command: true, shift: true)
        case .showHideAllWindows: return Self.shortcut(key: ".", command: true, option: true, control: true)
        case .globalSearch: return Self.shortcut(key: "f", command: true, option: true)
        case .newWindow: return Self.shortcut(key: "n", command: true, shift: true)
        case .closeWindow: return Self.shortcut(key: "w", command: true, control: true)
        case .toggleFullScreen: return Self.shortcut(key: "f", command: true, control: true)
        case .quit: return Self.shortcut(key: "q", command: true)
        case .toggleSidebar: return Self.shortcut(key: "b", command: true)
        case .newTab: return Self.shortcut(key: "n", command: true)
        case .newBrowserWorkspace: return Self.shortcut(key: "n", command: true, option: true)
        case .openFolder: return Self.shortcut(key: "o", command: true)
        case .reopenPreviousSession: return Self.shortcut(key: "o", command: true, shift: true)
        case .goToWorkspace: return Self.shortcut(key: "p", command: true)
        case .commandPalette: return Self.shortcut(key: "p", command: true, shift: true)
        case .commandPaletteNext: return Self.shortcut(key: "n", control: true)
        case .commandPalettePrevious: return Self.shortcut(key: "p", control: true)
        case .sendFeedback: return nil
        case .showNotifications: return Self.shortcut(key: "i", command: true)
        case .jumpToUnread: return Self.shortcut(key: "u", command: true, shift: true)
        case .toggleUnread: return Self.shortcut(key: "u", command: true, option: true)
        case .markOldestUnreadAndJumpNext: return Self.shortcut(key: "u", command: true, control: true)
        case .focusRightSidebar: return Self.shortcut(key: "e", command: true, shift: true)
        case .switchRightSidebarToFiles: return Self.shortcut(key: "1", control: true)
        case .switchRightSidebarToFind: return Self.shortcut(key: "2", control: true)
        case .switchRightSidebarToSessions: return Self.shortcut(key: "3", control: true)
        case .switchRightSidebarToFeed: return Self.shortcut(key: "4", control: true)
        case .switchRightSidebarToDock: return Self.shortcut(key: "5", control: true)
        case .triggerFlash: return Self.shortcut(key: "h", command: true, shift: true)
        case .nextSidebarTab: return Self.shortcut(key: "]", command: true, control: true)
        case .prevSidebarTab: return Self.shortcut(key: "[", command: true, control: true)
        case .focusHistoryBack: return Self.shortcut(key: "[", command: true)
        case .focusHistoryForward: return Self.shortcut(key: "]", command: true)
        case .renameTab: return Self.shortcut(key: "r", command: true)
        case .renameWorkspace: return Self.shortcut(key: "r", command: true, shift: true)
        case .editWorkspaceDescription: return Self.shortcut(key: "e", command: true, option: true)
        case .closeTab: return Self.shortcut(key: "w", command: true)
        case .closeOtherTabsInPane: return Self.shortcut(key: "t", command: true, option: true)
        case .closeWorkspace: return Self.shortcut(key: "w", command: true, shift: true)
        case .groupSelectedWorkspaces: return Self.shortcut(key: "g", command: true, shift: true)
        case .toggleFocusedWorkspaceGroupCollapsed: return Self.shortcut(key: ".", command: true, control: true)
        case .reopenClosedBrowserPanel: return Self.shortcut(key: "t", command: true, shift: true)
        case .focusLeft: return Self.shortcut(key: "←", command: true, option: true)
        case .focusRight: return Self.shortcut(key: "→", command: true, option: true)
        case .focusUp: return Self.shortcut(key: "↑", command: true, option: true)
        case .focusDown: return Self.shortcut(key: "↓", command: true, option: true)
        case .resizeSplitLeft, .resizeSplitRight, .resizeSplitUp, .resizeSplitDown:
            return nil
        case .splitRight: return Self.shortcut(key: "d", command: true)
        case .splitDown: return Self.shortcut(key: "d", command: true, shift: true)
        case .toggleSplitZoom: return Self.shortcut(key: "\r", command: true, shift: true)
        case .equalizeSplits: return Self.shortcut(key: "=", command: true, control: true)
        case .splitBrowserRight: return Self.shortcut(key: "d", command: true, option: true)
        case .splitBrowserDown: return Self.shortcut(key: "d", command: true, shift: true, option: true)
        case .toggleCanvasLayout: return Self.shortcut(key: "c", command: true, control: true)
        case .canvasRevealFocusedPane: return Self.shortcut(key: "r", command: true, control: true)
        case .canvasOverview: return Self.shortcut(key: "o", command: true, control: true)
        case .canvasZoomIn: return Self.shortcut(key: "=", command: true, option: true)
        case .canvasZoomOut: return Self.shortcut(key: "-", command: true, option: true)
        case .canvasZoomReset: return Self.shortcut(key: "0", command: true, option: true)
        case .canvasTidy: return Self.shortcut(key: "t", command: true, control: true)
        case .canvasAlignLeft, .canvasAlignRight, .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally, .canvasDistributeVertically:
            return nil
        case .nextSurface: return Self.shortcut(key: "]", command: true, shift: true)
        case .prevSurface: return Self.shortcut(key: "[", command: true, shift: true)
        case .selectSurfaceByNumber: return Self.shortcut(key: "1", control: true)
        case .selectWorkspaceByNumber: return Self.shortcut(key: "1", command: true)
        case .newSurface: return Self.shortcut(key: "t", command: true)
        case .toggleTerminalCopyMode: return Self.shortcut(key: "m", command: true, shift: true)
        case .focusTextBoxInput: return Self.shortcut(key: "a", command: true, shift: true)
        case .attachTextBoxFile: return Self.shortcut(key: "a", command: true, shift: true, option: true)
        case .sendCtrlFToTerminal: return nil
        case .toggleRightSidebar: return Self.shortcut(key: "b", command: true, option: true)
        case .openDiffViewer: return Self.shortcut(key: "d", command: true, shift: true, control: true)
        case .saveFilePreview: return Self.shortcut(key: "s", command: true)
        case .openBrowser: return Self.shortcut(key: "l", command: true, shift: true)
        case .focusBrowserAddressBar: return Self.shortcut(key: "l", command: true)
        case .browserBack: return Self.shortcut(key: "[", command: true)
        case .browserForward: return Self.shortcut(key: "]", command: true)
        case .browserReload: return Self.shortcut(key: "r", command: true)
        case .browserZoomIn: return Self.shortcut(key: "=", command: true)
        case .browserZoomOut: return Self.shortcut(key: "-", command: true)
        case .browserZoomReset: return Self.shortcut(key: "0", command: true)
        case .markdownZoomIn: return Self.shortcut(key: "=", command: true)
        case .markdownZoomOut: return Self.shortcut(key: "-", command: true)
        case .markdownZoomReset: return Self.shortcut(key: "0", command: true)
        case .find: return Self.shortcut(key: "f", command: true)
        case .findInDirectory: return Self.shortcut(key: "f", command: true, shift: true)
        case .findNext: return Self.shortcut(key: "g", command: true)
        case .findPrevious: return Self.shortcut(key: "g", command: true, option: true)
        case .hideFind: return Self.shortcut(key: "f", command: true, shift: true, option: true)
        case .useSelectionForFind: return Self.shortcut(key: "e", command: true)
        case .toggleBrowserDeveloperTools: return Self.shortcut(key: "i", command: true, option: true)
        case .showBrowserJavaScriptConsole: return Self.shortcut(key: "c", command: true, option: true)
        case .toggleBrowserFocusMode: return Self.shortcut(key: "\r", command: true, option: true)
        case .toggleReactGrab: return Self.shortcut(key: "g", command: true, shift: true)
        case .diffViewerScrollDown: return Self.shortcut(key: "j")
        case .diffViewerScrollUp: return Self.shortcut(key: "k")
        case .diffViewerScrollToBottom: return Self.shortcut(key: "g", shift: true)
        case .diffViewerScrollToTop:
            return StoredShortcut(
                first: ShortcutStroke(key: "g"),
                second: ShortcutStroke(key: "g")
            )
        case .diffViewerOpenFileSearch: return Self.shortcut(key: "/")
        }
    }

    /// The factory-default first stroke for single-stroke shortcuts.
    ///
    /// Chorded defaults return `nil`; use ``defaultShortcut`` when callers
    /// need to preserve the whole binding.
    public var defaultStroke: ShortcutStroke? {
        guard let shortcut = defaultShortcut, shortcut.second == nil else {
            return nil
        }
        return shortcut.first
    }

    private static func shortcut(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> StoredShortcut {
        StoredShortcut(
            first: ShortcutStroke(
                key: key,
                command: command,
                shift: shift,
                option: option,
                control: control
            )
        )
    }

}
