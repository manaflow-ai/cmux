/// Every configurable shortcut must make an explicit Dock-routing decision.
/// The exhaustive switch intentionally has no `default`: adding a new action
/// fails compilation until its ownership is classified.
enum DockShortcutRoutingDisposition {
    /// The action mutates or navigates a surface tree and must check the
    /// focused Dock before using the main TabManager.
    case dockScoped
    /// The action already resolves its target from the event's first
    /// responder or focused panel, which includes Dock-owned panels.
    case focusResolved
    /// The action intentionally targets app, window, workspace, sidebar, or
    /// Canvas state rather than either surface tree.
    case mainContainer
}

extension KeyboardShortcutSettings.Action {
    var dockShortcutRoutingDisposition: DockShortcutRoutingDisposition {
        switch self {
        case .triggerFlash,
             .nextSurface, .prevSurface,
             .moveSurfaceLeft, .moveSurfaceRight,
             .moveSurfaceToPreviousPane, .moveSurfaceToNextPane,
             .moveSurfaceToPaneLeft, .moveSurfaceToPaneRight,
             .moveSurfaceToPaneUp, .moveSurfaceToPaneDown,
             .selectSurfaceByNumber,
             .focusHistoryBack, .focusHistoryForward,
             .renameTab,
             .closeTab, .closeOtherTabsInPane,
             .reopenClosedBrowserPanel,
             .newSurface,
             .toggleTerminalCopyMode,
             .focusTextBoxInput, .attachTextBoxFile,
             .sendCtrlFToTerminal,
             .clearScreenKeepScrollback,
             .focusLeft, .focusRight, .focusUp, .focusDown,
             .focusPreviousPane, .focusNextPane,
             .splitRight, .splitDown, .toggleSplitZoom,
             .equalizeSplits,
             .splitBrowserRight, .splitBrowserDown,
             .openBrowser, .focusBrowserAddressBar,
             .find, .findNext, .findPrevious, .hideFind,
             .useSelectionForFind,
             .toggleReactGrab:
            .dockScoped

        case .commandPaletteNext, .commandPalettePrevious,
             .toggleChecklistItemComplete,
             .cycleTextBoxSubmitAction,
             .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias,
             .saveFilePreview,
             .browserBack, .browserForward,
             .browserReload, .browserHardReload,
             .browserZoomIn, .browserZoomOut, .browserZoomReset,
             .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole,
             .toggleBrowserFocusMode,
             .toggleBrowserDesignMode,
             .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .simulatorHome, .simulatorRotateLeft,
             .simulatorRotateRight,
             .simulatorToggleAppearance,
             .simulatorToggleSoftwareKeyboard,
             .diffViewerNextFile, .diffViewerPreviousFile:
            .focusResolved

        case .openSettings, .reloadConfiguration,
             .showHideAllWindows, .globalSearch,
             .newWindow, .closeWindow, .toggleFullScreen, .quit,
             .toggleSidebar, .newTab, .newBrowserWorkspace,
             .saveLayoutTemplate, .openFolder,
             .reopenPreviousSession, .goToWorkspace,
             .commandPalette, .sendFeedback,
             .showNotifications, .jumpToUnread, .toggleUnread,
             .markOldestUnreadAndJumpNext,
             .markAllNotificationsRead, .clearAllNotifications,
             .focusRightSidebar,
             .switchRightSidebarToFiles,
             .switchRightSidebarToFind,
             .switchRightSidebarToSessions,
             .switchRightSidebarToFeed,
             .switchRightSidebarToDock,
             .switchRightSidebarToMachines,
             .nextSidebarTab, .prevSidebarTab,
             .nextSidebarTabInGroup, .prevSidebarTabInGroup,
             .moveWorkspaceUp, .moveWorkspaceDown,
             .selectWorkspaceByNumber,
             .renameWorkspace, .editWorkspaceDescription,
             .markWorkspaceDone, .cycleWorkspaceStatus,
             .closeWorkspace,
             .newWorkspaceGroup, .groupSelectedWorkspaces,
             .toggleFocusedWorkspaceGroupCollapsed,
             .reopenClosedWorkspace,
             .increaseWorkspaceTerminalFontSize,
             .decreaseWorkspaceTerminalFontSize,
             .resetWorkspaceTerminalFontSize,
             .toggleCanvasLayout,
             .canvasRevealFocusedPane, .canvasOverview,
             .canvasZoomIn, .canvasZoomOut, .canvasZoomReset,
             .canvasTidy,
             .canvasAlignLeft, .canvasAlignRight,
             .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally,
             .canvasDistributeVertically,
             .toggleRightSidebar,
             .findInDirectory,
             .openDiffViewer:
            .mainContainer
        }
    }
}
