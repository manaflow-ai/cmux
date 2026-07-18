import Foundation

/// The stable, user-customisable shortcut actions cmux exposes. Each case is a
/// one-line identifier that maps to one user-facing behavior. The set is
/// intentionally flat (rather than nested by category) so the JSON config
/// representation stays readable (`"shortcuts.bindings": { "openSettings": "cmd+,", ... }`).
/// Display names + group categorization are metadata derived from the enum case in
/// extensions below; the raw value is the stable identifier persisted in cmux.json.
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
    case saveLayoutTemplate
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
    /// Moves the selected surface one position left.
    case moveSurfaceLeft
    /// Moves the selected surface one position right.
    case moveSurfaceRight
    case selectSurfaceByNumber
    case nextSidebarTab
    case prevSidebarTab
    /// Moves the selected workspace one position up within its pin tier.
    case moveWorkspaceUp
    /// Moves the selected workspace one position down within its pin tier.
    case moveWorkspaceDown
    case focusHistoryBack
    case focusHistoryForward
    case selectWorkspaceByNumber
    case renameTab
    case renameWorkspace
    case editWorkspaceDescription
    /// Sets the workspace's todo status override to done.
    case markWorkspaceDone
    /// Cycles the workspace's todo status override one lane forward.
    case cycleWorkspaceStatus
    /// Toggles the highlighted checklist item in the focused todo surface.
    case toggleChecklistItemComplete
    case closeTab
    case closeOtherTabsInPane
    case closeWorkspace
    /// Creates a new empty workspace group.
    case newWorkspaceGroup
    /// Groups the selected workspaces in the workspace list.
    case groupSelectedWorkspaces
    /// Toggles collapse for the group containing the focused workspace.
    case toggleFocusedWorkspaceGroupCollapsed
    case reopenClosedBrowserPanel
    case newSurface
    case toggleTerminalCopyMode
    case focusTextBoxInput
    /// Cycles the TextBox submit button to the next configured action.
    case cycleTextBoxSubmitAction
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
    /// Scrolls the focused viewer down half a page.
    case diffViewerScrollHalfPageDown
    /// Scrolls the focused viewer up half a page.
    case diffViewerScrollHalfPageUp
    /// Scrolls the focused viewer down one smooth step using the Emacs binding.
    case diffViewerScrollDownEmacs
    /// Scrolls the focused viewer up one smooth step using the Emacs binding.
    case diffViewerScrollUpEmacs
    /// Scrolls the focused diff viewer to the bottom.
    case diffViewerScrollToBottom
    /// Scrolls the focused diff viewer to the top.
    case diffViewerScrollToTop
    /// Opens file search inside the focused diff viewer.
    case diffViewerOpenFileSearch
    /// Jumps to the next file inside the focused diff viewer.
    case diffViewerNextFile
    /// Jumps to the previous file inside the focused diff viewer.
    case diffViewerPreviousFile

    // MARK: Simulator
    /// Presses the Home button in the focused Simulator pane.
    case simulatorHome
    /// Rotates the focused Simulator pane counterclockwise.
    case simulatorRotateLeft
    /// Rotates the focused Simulator pane clockwise.
    case simulatorRotateRight
    /// Toggles light and dark appearance in the focused Simulator pane.
    case simulatorToggleAppearance
    /// Toggles the software keyboard in the focused Simulator pane.
    case simulatorToggleSoftwareKeyboard
}

extension ShortcutAction {
    /// Which group this action belongs to in the settings pane.
    public var group: Group {
        switch self {
        case .openSettings, .reloadConfiguration, .showHideAllWindows, .globalSearch,
             .newWindow, .closeWindow, .toggleFullScreen, .quit:
            return .app
        case .toggleSidebar, .newTab, .newBrowserWorkspace, .saveLayoutTemplate, .openFolder, .reopenPreviousSession, .goToWorkspace,
             .commandPalette, .commandPaletteNext, .commandPalettePrevious, .sendFeedback,
             .showNotifications, .jumpToUnread, .toggleUnread, .markOldestUnreadAndJumpNext,
             .focusRightSidebar, .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed,
             .switchRightSidebarToDock, .triggerFlash:
            return .workspace
        case .nextSurface, .prevSurface, .moveSurfaceLeft, .moveSurfaceRight, .selectSurfaceByNumber,
             .nextSidebarTab, .prevSidebarTab, .moveWorkspaceUp, .moveWorkspaceDown, .focusHistoryBack, .focusHistoryForward,
             .selectWorkspaceByNumber, .renameTab, .renameWorkspace,
             .editWorkspaceDescription, .markWorkspaceDone, .cycleWorkspaceStatus, .toggleChecklistItemComplete, .closeTab, .closeOtherTabsInPane, .closeWorkspace,
             .newWorkspaceGroup, .groupSelectedWorkspaces, .toggleFocusedWorkspaceGroupCollapsed,
             .reopenClosedBrowserPanel, .newSurface, .toggleTerminalCopyMode,
             .focusTextBoxInput, .cycleTextBoxSubmitAction, .attachTextBoxFile, .sendCtrlFToTerminal,
             .clearScreenKeepScrollback:
            return .navigation
        case .focusLeft, .focusRight, .focusUp, .focusDown, .splitRight, .splitDown,
             .toggleSplitZoom, .equalizeSplits, .splitBrowserRight, .splitBrowserDown,
             .toggleRightSidebar, .fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias,
             .toggleCanvasLayout, .canvasRevealFocusedPane, .canvasOverview,
             .canvasZoomIn, .canvasZoomOut, .canvasZoomReset, .canvasTidy,
             .canvasAlignLeft, .canvasAlignRight, .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally, .canvasDistributeVertically,
             .simulatorHome, .simulatorRotateLeft, .simulatorRotateRight,
             .simulatorToggleAppearance, .simulatorToggleSoftwareKeyboard:
            return .panes
        case .openDiffViewer, .saveFilePreview, .openBrowser, .focusBrowserAddressBar, .browserBack,
             .browserForward, .browserReload, .browserHardReload, .browserZoomIn, .browserZoomOut,
             .browserZoomReset, .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .find, .findInDirectory, .findNext, .findPrevious,
             .hideFind, .useSelectionForFind, .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole, .toggleBrowserFocusMode, .toggleReactGrab,
             .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs, .diffViewerScrollToBottom,
             .diffViewerScrollToTop, .diffViewerOpenFileSearch,
             .diffViewerNextFile, .diffViewerPreviousFile:
            return .browser
        }
    }

    /// Whether this action binds the whole `1…9` digit range through a
    /// single stored placeholder.
    ///
    /// ``selectSurfaceByNumber`` and ``selectWorkspaceByNumber`` are special:
    /// one binding (with the digit normalized to `"1"`) stands in for the
    /// entire `⌘1`–`⌘9` / `⌃1`–`⌃9` family. UI that displays the binding
    /// should render it as `⌃1…9` (the range) rather than the literal
    /// single-digit `⌃1`, and recording any digit `1`–`9` rebinds the whole
    /// range. All other actions match a single concrete keystroke.
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
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .diffViewerNextFile,
             .diffViewerPreviousFile,
             .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias:
            return true
        default:
            return false
        }
    }

    /// Whether this action supports a two-stroke shortcut chord.
    public var allowsChordShortcut: Bool {
        self != .fileExplorerOpenSelection
            && self != .fileExplorerOpenSelectionFinderAlias
            && self != .cycleTextBoxSubmitAction
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
        case .commandPaletteNext, .commandPalettePrevious:
            return .key(ShortcutContextKnownKey.commandPaletteVisible.rawValue)
        case .renameTab, .renameWorkspace:
            return .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        case .sendCtrlFToTerminal, .clearScreenKeepScrollback:
            return .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        case .browserBack, .browserForward, .browserReload, .browserHardReload,
             .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole, .toggleBrowserFocusMode,
             .diffViewerOpenFileSearch, .diffViewerNextFile, .diffViewerPreviousFile:
            return .atom(.browserFocus)
        case .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs, .diffViewerScrollToBottom,
             .diffViewerScrollToTop:
            return .or(.atom(.browserFocus), .atom(.markdownFocus))
        case .browserZoomIn, .browserZoomOut, .browserZoomReset:
            return .or(.atom(.browserFocus), .atom(.filePreviewTextEditorFocus))
        case .markdownZoomIn, .markdownZoomOut, .markdownZoomReset:
            return .atom(.markdownFocus)
        case .simulatorHome, .simulatorRotateLeft, .simulatorRotateRight,
             .simulatorToggleAppearance, .simulatorToggleSoftwareKeyboard:
            return .atom(.simulatorFocus)
        case .canvasZoomIn, .canvasZoomOut, .canvasZoomReset:
            return .and(
                .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue),
                .and(
                    .not(.atom(.browserFocus)),
                    .and(
                        .not(.atom(.markdownFocus)),
                        .and(
                            .not(.atom(.filePreviewTextEditorFocus)),
                            .not(.atom(.simulatorFocus))
                        )
                    )
                )
            )
        case .canvasRevealFocusedPane, .canvasOverview,
             .canvasTidy,
             .canvasAlignLeft, .canvasAlignRight, .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally, .canvasDistributeVertically:
            return .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue)
        default:
            return .always
        }
    }

}
