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
        case .nextSurface, .prevSurface, .moveSurfaceLeft, .moveSurfaceRight,
             .moveSurfaceToPreviousPane, .moveSurfaceToNextPane,
             .moveSurfaceToPaneLeft, .moveSurfaceToPaneRight,
             .moveSurfaceToPaneUp, .moveSurfaceToPaneDown,
             .selectSurfaceByNumber,
             .nextSidebarTab, .prevSidebarTab, .moveWorkspaceUp, .moveWorkspaceDown,
             .focusHistoryBack, .focusHistoryForward, .selectWorkspaceByNumber,
             .renameTab, .renameWorkspace, .editWorkspaceDescription,
             .markWorkspaceDone, .cycleWorkspaceStatus, .toggleChecklistItemComplete,
             .closeTab, .closeOtherTabsInPane, .closeWorkspace,
             .newWorkspaceGroup, .groupSelectedWorkspaces,
             .toggleFocusedWorkspaceGroupCollapsed, .reopenClosedBrowserPanel,
             .newSurface, .toggleTerminalCopyMode, .focusTextBoxInput,
             .cycleTextBoxSubmitAction, .attachTextBoxFile, .sendCtrlFToTerminal,
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
        case .openDiffViewer, .saveFilePreview, .openBrowser, .focusBrowserAddressBar,
             .browserBack, .browserForward, .browserReload, .browserHardReload,
             .browserZoomIn, .browserZoomOut, .browserZoomReset,
             .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .find, .findInDirectory, .findNext, .findPrevious,
             .hideFind, .useSelectionForFind, .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole, .toggleBrowserFocusMode, .toggleReactGrab,
             .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom, .diffViewerScrollToTop,
             .diffViewerOpenFileSearch, .diffViewerNextFile, .diffViewerPreviousFile:
            return .browser
        }
    }

    /// Logical grouping used for sectioning the shortcuts pane.
    public enum Group: String, CaseIterable, Sendable, Hashable {
        /// Application-wide actions.
        case app
        /// Workspace lifecycle and notification actions.
        case workspace
        /// Workspace and surface navigation actions.
        case navigation
        /// Pane layout and focus actions.
        case panes
        /// Browser, viewer, and find actions.
        case browser

        /// The English section title used by shortcut catalog consumers.
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
}
