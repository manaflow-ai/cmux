import Foundation

extension ShortcutAction {
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
        case .saveLayoutTemplate:
            return String(localized: "shortcut.saveLayoutTemplate.label", defaultValue: "Save Layout as Template…")
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
        case .moveSurfaceLeft: return String(localized: "shortcut.moveSurfaceLeft.label", defaultValue: "Move Surface Left")
        case .moveSurfaceRight: return String(localized: "shortcut.moveSurfaceRight.label", defaultValue: "Move Surface Right")
        case .selectSurfaceByNumber: return "Select Surface 1…9"
        case .nextSidebarTab: return "Next Workspace"
        case .prevSidebarTab: return "Previous Workspace"
        case .moveWorkspaceUp: return String(localized: "shortcut.moveWorkspaceUp.label", defaultValue: "Move Workspace Up")
        case .moveWorkspaceDown: return String(localized: "shortcut.moveWorkspaceDown.label", defaultValue: "Move Workspace Down")
        case .focusHistoryBack: return "Focus Back"
        case .focusHistoryForward: return "Focus Forward"
        case .selectWorkspaceByNumber: return "Select Workspace 1…9"
        case .renameTab: return "Rename Tab"
        case .renameWorkspace: return "Rename Workspace"
        case .editWorkspaceDescription: return "Edit Workspace Description"
        case .markWorkspaceDone: return String(localized: "shortcut.markWorkspaceDone.label", defaultValue: "Mark Workspace as Done")
        case .cycleWorkspaceStatus: return String(localized: "shortcut.cycleWorkspaceStatus.label", defaultValue: "Cycle Workspace Status")
        case .toggleChecklistItemComplete: return String(localized: "shortcut.toggleChecklistItemComplete.label", defaultValue: "Toggle Checklist Item Complete")
        case .closeTab: return "Close Tab"
        case .closeOtherTabsInPane: return "Close Other Tabs in Pane"
        case .closeWorkspace: return "Close Workspace"
        case .newWorkspaceGroup:
            return String(localized: "shortcut.newWorkspaceGroup.label", defaultValue: "New Workspace Group")
        case .groupSelectedWorkspaces:
            return String(localized: "shortcut.groupSelectedWorkspaces.label", defaultValue: "Group Selected Workspaces")
        case .toggleFocusedWorkspaceGroupCollapsed:
            return String(localized: "shortcut.toggleFocusedWorkspaceGroupCollapsed.label", defaultValue: "Toggle Focused Workspace's Group Collapse")
        case .reopenClosedBrowserPanel: return "Reopen Last Closed"
        case .newSurface: return "New Surface"
        case .toggleTerminalCopyMode: return "Toggle Terminal Copy Mode"
        case .focusTextBoxInput: return "Focus TextBox Input"
        case .cycleTextBoxSubmitAction:
            return String(localized: "shortcut.cycleTextBoxSubmitAction.label", defaultValue: "Cycle TextBox Submit Action")
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
            return String(localized: "shortcut.diffViewerScrollDown.label", defaultValue: "Viewers: Scroll Down")
        case .diffViewerScrollUp:
            return String(localized: "shortcut.diffViewerScrollUp.label", defaultValue: "Viewers: Scroll Up")
        case .diffViewerScrollHalfPageDown:
            return String(localized: "shortcut.diffViewerScrollHalfPageDown.label", defaultValue: "Viewers: Scroll Half Page Down")
        case .diffViewerScrollHalfPageUp:
            return String(localized: "shortcut.diffViewerScrollHalfPageUp.label", defaultValue: "Viewers: Scroll Half Page Up")
        case .diffViewerScrollDownEmacs:
            return String(localized: "shortcut.diffViewerScrollDownEmacs.label", defaultValue: "Viewers: Scroll Down (Emacs)")
        case .diffViewerScrollUpEmacs:
            return String(localized: "shortcut.diffViewerScrollUpEmacs.label", defaultValue: "Viewers: Scroll Up (Emacs)")
        case .diffViewerScrollToBottom:
            return String(localized: "shortcut.diffViewerScrollToBottom.label", defaultValue: "Viewers: Scroll to Bottom")
        case .diffViewerScrollToTop:
            return String(localized: "shortcut.diffViewerScrollToTop.label", defaultValue: "Viewers: Scroll to Top")
        case .diffViewerOpenFileSearch:
            return String(localized: "shortcut.diffViewerOpenFileSearch.label", defaultValue: "Diff Viewer: Open File Search")
        case .diffViewerNextFile:
            return String(localized: "shortcut.diffViewerNextFile.label", defaultValue: "Diff Viewer: Next File")
        case .diffViewerPreviousFile:
            return String(localized: "shortcut.diffViewerPreviousFile.label", defaultValue: "Diff Viewer: Previous File")
        case .simulatorHome:
            return String(localized: "shortcut.simulatorHome.label", defaultValue: "Simulator: Home")
        case .simulatorRotateLeft:
            return String(localized: "shortcut.simulatorRotateLeft.label", defaultValue: "Simulator: Rotate Left")
        case .simulatorRotateRight:
            return String(localized: "shortcut.simulatorRotateRight.label", defaultValue: "Simulator: Rotate Right")
        case .simulatorToggleAppearance:
            return String(localized: "shortcut.simulatorToggleAppearance.label", defaultValue: "Simulator: Toggle Appearance")
        case .simulatorToggleSoftwareKeyboard:
            return String(localized: "shortcut.simulatorToggleSoftwareKeyboard.label", defaultValue: "Simulator: Toggle Software Keyboard")
        }
    }
}
