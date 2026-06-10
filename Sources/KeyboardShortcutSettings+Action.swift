import AppKit
import Bonsplit
import Carbon
import SwiftUI


// MARK: - Action model + shortcut conflict resolution
extension KeyboardShortcutSettings {
    enum Action: String, CaseIterable, Identifiable {
        // App / window
        case openSettings
        case reloadConfiguration
        case showHideAllWindows
        case globalSearch
        case newWindow
        case closeWindow
        case toggleFullScreen
        case quit

        // Titlebar / primary UI
        case toggleSidebar
        case newTab
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

        // Navigation
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
        case groupSelectedWorkspaces
        case toggleFocusedWorkspaceGroupCollapsed
        case reopenClosedBrowserPanel
        case newSurface
        case toggleTerminalCopyMode
        case focusTextBoxInput
        case attachTextBoxFile
        case sendCtrlFToTerminal

        // Panes / splits
        case focusLeft
        case focusRight
        case focusUp
        case focusDown
        case splitRight
        case splitDown, toggleSplitZoom
        case equalizeSplits
        case splitBrowserRight
        case splitBrowserDown

        // File Explorer
        case toggleRightSidebar = "toggleFileExplorer"

        // Panels
        case saveFilePreview
        case openBrowser
        case focusBrowserAddressBar
        case browserBack
        case browserForward
        case browserReload
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
        case openDiffViewer
        case diffViewerScrollDown
        case diffViewerScrollUp
        case diffViewerScrollToBottom
        case diffViewerScrollToTop
        case diffViewerOpenFileSearch

        var id: String { rawValue }

        var label: String {
            switch self {
            case .openSettings: return String(localized: "menu.app.settings", defaultValue: "Settings…")
            case .reloadConfiguration: return String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration")
            case .showHideAllWindows: return String(localized: "settings.globalHotkey.shortcut", defaultValue: "Show/Hide All Windows")
            case .globalSearch: return String(localized: "shortcut.globalSearch.label", defaultValue: "Global Search")
            case .newWindow: return String(localized: "shortcut.newWindow.label", defaultValue: "New Window")
            case .closeWindow: return String(localized: "shortcut.closeWindow.label", defaultValue: "Close Window")
            case .toggleFullScreen: return String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")
            case .quit: return String(localized: "menu.quitCmux", defaultValue: "Quit cmux")
            case .toggleSidebar: return String(localized: "shortcut.toggleLeftSidebar.label", defaultValue: "Toggle Left Sidebar")
            case .newTab: return String(localized: "shortcut.newWorkspace.label", defaultValue: "New Workspace")
            case .openFolder: return String(localized: "shortcut.openFolder.label", defaultValue: "Open Folder")
            case .reopenPreviousSession: return String(localized: "shortcut.reopenPreviousSession.label", defaultValue: "Restore Previous App Launch")
            case .goToWorkspace: return String(localized: "menu.file.goToWorkspace", defaultValue: "Go to Workspace…")
            case .commandPalette: return String(localized: "menu.file.commandPalette", defaultValue: "Command Palette…")
            case .commandPaletteNext: return String(localized: "shortcut.commandPaletteNext.label", defaultValue: "Command Palette: Next")
            case .commandPalettePrevious: return String(localized: "shortcut.commandPalettePrevious.label", defaultValue: "Command Palette: Previous")
            case .sendFeedback: return String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback")
            case .showNotifications: return String(localized: "shortcut.showNotifications.label", defaultValue: "Show Notifications")
            case .jumpToUnread: return String(localized: "shortcut.jumpToUnread.label", defaultValue: "Jump to Latest Unread")
            case .toggleUnread: return String(localized: "shortcut.toggleUnread.label", defaultValue: "Toggle Unread")
            case .markOldestUnreadAndJumpNext:
                return String(localized: "shortcut.markOldestUnreadAndJumpNext.label", defaultValue: "Mark as Oldest Unread and Jump to Next Latest Unread")
            case .focusRightSidebar: return String(localized: "shortcut.focusRightSidebar.label", defaultValue: "Toggle Right Sidebar Focus")
            case .switchRightSidebarToFiles: return String(localized: "shortcut.switchRightSidebarToFiles.label", defaultValue: "Show Sidebar Files")
            case .switchRightSidebarToFind: return String(localized: "shortcut.switchRightSidebarToFind.label", defaultValue: "Show Sidebar Find")
            case .switchRightSidebarToSessions: return String(localized: "shortcut.switchRightSidebarToSessions.label", defaultValue: "Show Sidebar Vault")
            case .switchRightSidebarToFeed: return String(localized: "shortcut.switchRightSidebarToFeed.label", defaultValue: "Show Sidebar Feed")
            case .switchRightSidebarToDock: return String(localized: "shortcut.switchRightSidebarToDock.label", defaultValue: "Show Sidebar Dock")
            case .triggerFlash: return String(localized: "shortcut.flashFocusedPanel.label", defaultValue: "Flash Focused Panel")
            case .nextSurface: return String(localized: "shortcut.nextSurface.label", defaultValue: "Next Surface")
            case .prevSurface: return String(localized: "shortcut.previousSurface.label", defaultValue: "Previous Surface")
            case .selectSurfaceByNumber: return String(localized: "shortcut.selectSurfaceByNumber.label", defaultValue: "Select Surface 1…9")
            case .nextSidebarTab: return String(localized: "shortcut.nextWorkspace.label", defaultValue: "Next Workspace")
            case .prevSidebarTab: return String(localized: "shortcut.previousWorkspace.label", defaultValue: "Previous Workspace")
            case .focusHistoryBack: return String(localized: "shortcut.focusHistoryBack.label", defaultValue: "Focus Back")
            case .focusHistoryForward: return String(localized: "shortcut.focusHistoryForward.label", defaultValue: "Focus Forward")
            case .selectWorkspaceByNumber: return String(localized: "shortcut.selectWorkspaceByNumber.label", defaultValue: "Select Workspace 1…9")
            case .renameTab: return String(localized: "shortcut.renameTab.label", defaultValue: "Rename Tab")
            case .renameWorkspace: return String(localized: "shortcut.renameWorkspace.label", defaultValue: "Rename Workspace")
            case .editWorkspaceDescription: return String(localized: "shortcut.editWorkspaceDescription.label", defaultValue: "Edit Workspace Description")
            case .closeTab: return String(localized: "menu.file.closeTab", defaultValue: "Close Tab")
            case .closeOtherTabsInPane: return String(localized: "menu.file.closeOtherTabs", defaultValue: "Close Other Tabs in Pane")
            case .closeWorkspace: return String(localized: "shortcut.closeWorkspace.label", defaultValue: "Close Workspace")
            case .groupSelectedWorkspaces: return String(localized: "shortcut.groupSelectedWorkspaces.label", defaultValue: "Group Selected Workspaces")
            case .toggleFocusedWorkspaceGroupCollapsed: return String(localized: "shortcut.toggleFocusedWorkspaceGroupCollapsed.label", defaultValue: "Toggle Focused Workspace's Group Collapse")
            case .reopenClosedBrowserPanel: return String(localized: "menu.history.reopenLastClosed", defaultValue: "Reopen Last Closed")
            case .newSurface: return String(localized: "shortcut.newSurface.label", defaultValue: "New Surface")
            case .toggleTerminalCopyMode: return String(localized: "shortcut.toggleTerminalCopyMode.label", defaultValue: "Toggle Terminal Copy Mode")
            case .focusTextBoxInput: return String(localized: "shortcut.focusTextBoxInput.label", defaultValue: "Focus TextBox Input")
            case .attachTextBoxFile: return String(localized: "shortcut.attachTextBoxFile.label", defaultValue: "Attach File to TextBox Input")
            case .sendCtrlFToTerminal: return String(localized: "shortcut.sendCtrlFToTerminal.label", defaultValue: "Send Ctrl-F to Terminal")
            case .focusLeft: return String(localized: "shortcut.focusPaneLeft.label", defaultValue: "Focus Pane Left")
            case .focusRight: return String(localized: "shortcut.focusPaneRight.label", defaultValue: "Focus Pane Right")
            case .focusUp: return String(localized: "shortcut.focusPaneUp.label", defaultValue: "Focus Pane Up")
            case .focusDown: return String(localized: "shortcut.focusPaneDown.label", defaultValue: "Focus Pane Down")
            case .splitRight: return String(localized: "shortcut.splitRight.label", defaultValue: "Split Right")
            case .splitDown: return String(localized: "shortcut.splitDown.label", defaultValue: "Split Down")
            case .toggleSplitZoom: return String(localized: "shortcut.togglePaneZoom.label", defaultValue: "Toggle Pane Zoom")
            case .equalizeSplits: return String(localized: "shortcut.equalizeSplits.label", defaultValue: "Equalize Splits")
            case .splitBrowserRight: return String(localized: "shortcut.splitBrowserRight.label", defaultValue: "Split Browser Right")
            case .splitBrowserDown: return String(localized: "shortcut.splitBrowserDown.label", defaultValue: "Split Browser Down")
            case .toggleRightSidebar: return String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar")
            case .saveFilePreview: return String(localized: "shortcut.saveFilePreview.label", defaultValue: "Save File Preview")
            case .openBrowser: return String(localized: "shortcut.openBrowser.label", defaultValue: "Open Browser")
            case .focusBrowserAddressBar: return String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")
            case .browserBack: return String(localized: "menu.view.back", defaultValue: "Back")
            case .browserForward: return String(localized: "menu.view.forward", defaultValue: "Forward")
            case .browserReload: return String(localized: "menu.view.reloadPage", defaultValue: "Reload Page")
            case .browserZoomIn: return String(localized: "menu.view.zoomIn", defaultValue: "Zoom In")
            case .browserZoomOut: return String(localized: "menu.view.zoomOut", defaultValue: "Zoom Out")
            case .browserZoomReset: return String(localized: "menu.view.actualSize", defaultValue: "Actual Size")
            case .markdownZoomIn: return String(localized: "shortcut.markdownZoomIn.label", defaultValue: "Markdown Viewer: Zoom In")
            case .markdownZoomOut: return String(localized: "shortcut.markdownZoomOut.label", defaultValue: "Markdown Viewer: Zoom Out")
            case .markdownZoomReset: return String(localized: "shortcut.markdownZoomReset.label", defaultValue: "Markdown Viewer: Actual Size")
            case .find: return String(localized: "menu.find.find", defaultValue: "Find…")
            case .findInDirectory: return String(localized: "menu.find.findInDirectory", defaultValue: "Find in Directory…")
            case .findNext: return String(localized: "menu.find.findNext", defaultValue: "Find Next")
            case .findPrevious: return String(localized: "menu.find.findPrevious", defaultValue: "Find Previous")
            case .hideFind: return String(localized: "menu.find.hideFindBar", defaultValue: "Hide Find Bar")
            case .useSelectionForFind: return String(localized: "menu.find.useSelectionForFind", defaultValue: "Use Selection for Find")
            case .toggleBrowserDeveloperTools: return String(localized: "shortcut.toggleBrowserDevTools.label", defaultValue: "Toggle Browser Developer Tools")
            case .showBrowserJavaScriptConsole: return String(localized: "shortcut.showBrowserJSConsole.label", defaultValue: "Show Browser JavaScript Console")
            case .toggleBrowserFocusMode: return String(localized: "shortcut.toggleBrowserFocusMode.label", defaultValue: "Enter Browser Focus Mode")
            case .toggleReactGrab: return String(localized: "shortcut.toggleReactGrab.label", defaultValue: "Toggle React Grab")
            case .openDiffViewer: return String(localized: "shortcut.openDiffViewer.label", defaultValue: "Open Diff Viewer")
            case .diffViewerScrollDown: return String(localized: "shortcut.diffViewerScrollDown.label", defaultValue: "Diff Viewer: Scroll Down")
            case .diffViewerScrollUp: return String(localized: "shortcut.diffViewerScrollUp.label", defaultValue: "Diff Viewer: Scroll Up")
            case .diffViewerScrollToBottom: return String(localized: "shortcut.diffViewerScrollToBottom.label", defaultValue: "Diff Viewer: Scroll to Bottom")
            case .diffViewerScrollToTop: return String(localized: "shortcut.diffViewerScrollToTop.label", defaultValue: "Diff Viewer: Scroll to Top")
            case .diffViewerOpenFileSearch: return String(localized: "shortcut.diffViewerOpenFileSearch.label", defaultValue: "Diff Viewer: Open File Search")
            }
        }

        var defaultsKey: String { "shortcut.\(rawValue)" }

        var isPublicShortcutAction: Bool {
            switch self {
            case .switchRightSidebarToFiles,
                 .switchRightSidebarToFind,
                 .switchRightSidebarToSessions,
                 .switchRightSidebarToFeed,
                 .switchRightSidebarToDock:
                return false
            default:
                return true
            }
        }

        var defaultShortcut: StoredShortcut {
            switch self {
            case .openSettings:
                return StoredShortcut(key: ",", command: true, shift: false, option: false, control: false)
            case .reloadConfiguration:
                return StoredShortcut(key: ",", command: true, shift: true, option: false, control: false)
            case .showHideAllWindows:
                // Avoid AppKit-reserved keystrokes such as Cmd+. (modal
                // cancel). Default to Ctrl+Option+Cmd+. so the global hotkey
                // does not collide with the standard cancel keystroke that
                // NSAlert/NSOpenPanel use.
                return StoredShortcut(key: ".", command: true, shift: false, option: true, control: true)
            case .globalSearch:
                return StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
            case .newWindow:
                return StoredShortcut(key: "n", command: true, shift: true, option: false, control: false)
            case .closeWindow:
                return StoredShortcut(key: "w", command: true, shift: false, option: false, control: true)
            case .toggleFullScreen:
                return StoredShortcut(key: "f", command: true, shift: false, option: false, control: true)
            case .quit:
                return StoredShortcut(key: "q", command: true, shift: false, option: false, control: false)
            case .toggleSidebar:
                return StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
            case .newTab:
                return StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
            case .openFolder:
                return StoredShortcut(key: "o", command: true, shift: false, option: false, control: false)
            case .reopenPreviousSession:
                return StoredShortcut(key: "o", command: true, shift: true, option: false, control: false)
            case .goToWorkspace:
                return StoredShortcut(key: "p", command: true, shift: false, option: false, control: false)
            case .commandPalette:
                return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false)
            case .commandPaletteNext:
                return StoredShortcut(key: "n", command: false, shift: false, option: false, control: true)
            case .commandPalettePrevious:
                return StoredShortcut(key: "p", command: false, shift: false, option: false, control: true)
            case .sendFeedback:
                return .unbound
            case .showNotifications:
                return StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
            case .jumpToUnread:
                return StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)
            case .toggleUnread:
                return StoredShortcut(key: "u", command: true, shift: false, option: true, control: false)
            case .markOldestUnreadAndJumpNext:
                return StoredShortcut(key: "u", command: true, shift: false, option: false, control: true)
            case .focusRightSidebar:
                return StoredShortcut(key: "e", command: true, shift: true, option: false, control: false)
            case .switchRightSidebarToFiles:
                return StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToFind:
                return StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToSessions:
                return StoredShortcut(key: "3", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToFeed:
                return StoredShortcut(key: "4", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToDock:
                return StoredShortcut(key: "5", command: false, shift: false, option: false, control: true)
            case .triggerFlash:
                return StoredShortcut(key: "h", command: true, shift: true, option: false, control: false)
            case .nextSidebarTab:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: true)
            case .prevSidebarTab:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: true)
            case .focusHistoryBack:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: false)
            case .focusHistoryForward:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: false)
            case .renameTab:
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
            case .renameWorkspace:
                return StoredShortcut(key: "r", command: true, shift: true, option: false, control: false)
            case .editWorkspaceDescription:
                return StoredShortcut(key: "e", command: true, shift: false, option: true, control: false)
            case .closeTab:
                return StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)
            case .closeOtherTabsInPane:
                return StoredShortcut(key: "t", command: true, shift: false, option: true, control: false)
            case .closeWorkspace:
                return StoredShortcut(key: "w", command: true, shift: true, option: false, control: false)
            case .groupSelectedWorkspaces:
                // Cmd+Shift+G is the user-natural mnemonic. It collides with
                // toggleReactGrab's default, but handleGroupSelectedWorkspacesShortcut
                // returns false (lets the event propagate) whenever there are
                // no eligible workspaces to group — so React Grab still
                // fires in browser/terminal contexts where this shortcut
                // wouldn't have done anything anyway.
                return StoredShortcut(key: "g", command: true, shift: true, option: false, control: false)
            case .toggleFocusedWorkspaceGroupCollapsed:
                // Ctrl+Cmd+period — matches the Ctrl+Cmd modifier family
                // used by other group ops, with "." as the collapse
                // mnemonic. No-ops gracefully when the focused workspace
                // isn't in a group.
                return StoredShortcut(key: ".", command: true, shift: false, option: false, control: true)
            case .reopenClosedBrowserPanel:
                return StoredShortcut(key: "t", command: true, shift: true, option: false, control: false)
            case .focusLeft:
                return StoredShortcut(key: "←", command: true, shift: false, option: true, control: false)
            case .focusRight:
                return StoredShortcut(key: "→", command: true, shift: false, option: true, control: false)
            case .focusUp:
                return StoredShortcut(key: "↑", command: true, shift: false, option: true, control: false)
            case .focusDown:
                return StoredShortcut(key: "↓", command: true, shift: false, option: true, control: false)
            case .splitRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            case .splitDown: return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
            case .toggleSplitZoom: return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
            case .equalizeSplits: return StoredShortcut(key: "=", command: true, shift: false, option: false, control: true)
            case .splitBrowserRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: true, control: false)
            case .splitBrowserDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: true, control: false)
            case .nextSurface:
                return StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
            case .prevSurface:
                return StoredShortcut(key: "[", command: true, shift: true, option: false, control: false)
            case .selectSurfaceByNumber:
                return StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
            case .newSurface:
                return StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            case .toggleTerminalCopyMode:
                return StoredShortcut(key: "m", command: true, shift: true, option: false, control: false)
            case .focusTextBoxInput:
                return StoredShortcut(key: "a", command: true, shift: true, option: false, control: false)
            case .attachTextBoxFile:
                return StoredShortcut(key: "a", command: true, shift: true, option: true, control: false)
            case .sendCtrlFToTerminal:
                // Unbound by default: this is a deliberate escape hatch for forwarding a
                // control chord (e.g. Claude Code's Ctrl-F force-stop) to the focused
                // terminal. Binding it to plain Ctrl-F would be self-referential, so users
                // opt in via Settings; it stays reachable through the command palette and
                // the `send_key ctrl-f` socket command.
                return .unbound
            case .selectWorkspaceByNumber:
                return StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
            case .toggleRightSidebar:
                return StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
            case .saveFilePreview:
                return StoredShortcut(key: "s", command: true, shift: false, option: false, control: false)
            case .openBrowser:
                return StoredShortcut(key: "l", command: true, shift: true, option: false, control: false)
            case .focusBrowserAddressBar:
                return StoredShortcut(key: "l", command: true, shift: false, option: false, control: false)
            case .browserBack:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: false)
            case .browserForward:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: false)
            case .browserReload:
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
            case .browserZoomIn:
                return StoredShortcut(key: "=", command: true, shift: false, option: false, control: false)
            case .browserZoomOut:
                return StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
            case .browserZoomReset:
                return StoredShortcut(key: "0", command: true, shift: false, option: false, control: false)
            case .markdownZoomIn:
                // Same chord as browser zoom, but scoped to the markdown panel
                // context so the two never collide.
                return StoredShortcut(key: "=", command: true, shift: false, option: false, control: false)
            case .markdownZoomOut:
                return StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
            case .markdownZoomReset:
                return StoredShortcut(key: "0", command: true, shift: false, option: false, control: false)
            case .find:
                return StoredShortcut(key: "f", command: true, shift: false, option: false, control: false)
            case .findInDirectory:
                return StoredShortcut(key: "f", command: true, shift: true, option: false, control: false)
            case .findNext:
                return StoredShortcut(key: "g", command: true, shift: false, option: false, control: false)
            case .findPrevious:
                return StoredShortcut(key: "g", command: true, shift: false, option: true, control: false)
            case .hideFind:
                return StoredShortcut(key: "f", command: true, shift: true, option: true, control: false)
            case .useSelectionForFind:
                return StoredShortcut(key: "e", command: true, shift: false, option: false, control: false)
            case .toggleBrowserDeveloperTools:
                // Safari default: Show Web Inspector.
                return StoredShortcut(key: "i", command: true, shift: false, option: true, control: false)
            case .showBrowserJavaScriptConsole:
                // Safari default: Show JavaScript Console.
                return StoredShortcut(key: "c", command: true, shift: false, option: true, control: false)
            case .toggleBrowserFocusMode:
                // Option+Cmd+Return: "enter" focus mode mnemonic. Option+Cmd is a
                // modifier tier web pages rarely bind, so it stays out of the page's
                // way while focus mode is off and cmux owns the shortcut, and it
                // avoids the Ctrl+Cmd+Return global hotkey some screen recorders use.
                // Exit stays double-Escape; rebind in Settings or cmux.json.
                return StoredShortcut(key: "\r", command: true, shift: false, option: true, control: false)
            case .toggleReactGrab:
                return StoredShortcut(key: "g", command: true, shift: true, option: false, control: false)
            case .openDiffViewer:
                // Cmd+Ctrl+Shift+D. The plain Cmd+Ctrl+D chord is reserved by macOS for
                // "Look Up & data detectors" — the OS swallows it before it reaches the
                // app's key monitor — and the rest of the Cmd-based "D" family is taken
                // by split actions (Cmd+D, Cmd+Shift+D, Cmd+Opt+D, Cmd+Shift+Opt+D).
                // Adding Shift yields a chord that reaches cmux while keeping the "D for
                // Diff" mnemonic. Rebindable in Settings → Keyboard Shortcuts.
                return StoredShortcut(key: "d", command: true, shift: true, option: false, control: true)
            case .diffViewerScrollDown:
                return StoredShortcut(key: "j", command: false, shift: false, option: false, control: false)
            case .diffViewerScrollUp:
                return StoredShortcut(key: "k", command: false, shift: false, option: false, control: false)
            case .diffViewerScrollToBottom:
                return StoredShortcut(key: "g", command: false, shift: true, option: false, control: false)
            case .diffViewerScrollToTop:
                return StoredShortcut(
                    first: ShortcutStroke(key: "g", command: false, shift: false, option: false, control: false),
                    second: ShortcutStroke(key: "g", command: false, shift: false, option: false, control: false)
                )
            case .diffViewerOpenFileSearch:
                return StoredShortcut(key: "/", command: false, shift: false, option: false, control: false)
            }
        }

        func tooltip(_ base: String) -> String {
            "\(base) (\(displayedShortcutString(for: KeyboardShortcutSettings.shortcut(for: self))))"
        }

        var usesNumberedDigitMatching: Bool {
            switch self {
            case .selectSurfaceByNumber, .selectWorkspaceByNumber:
                return true
            default:
                return false
            }
        }

        var allowsBareFirstStroke: Bool {
            switch self {
            case .diffViewerScrollDown,
                 .diffViewerScrollUp,
                 .diffViewerScrollToBottom,
                 .diffViewerScrollToTop,
                 .diffViewerOpenFileSearch:
                return true
            default:
                return false
            }
        }

        var isBrowserContentShortcut: Bool {
            switch self {
            case .diffViewerScrollDown,
                 .diffViewerScrollUp,
                 .diffViewerScrollToBottom,
                 .diffViewerScrollToTop,
                 .diffViewerOpenFileSearch:
                return true
            default:
                return false
            }
        }

        func displayedShortcutString(for shortcut: StoredShortcut) -> String {
            if shortcut.isUnbound {
                return shortcut.displayString
            }
            if usesNumberedDigitMatching {
                return shortcut.numberedDisplayString
            }
            return shortcut.displayString
        }

        func conflicts(
            with proposedShortcut: StoredShortcut,
            proposedAction: Action,
            configuredShortcut: StoredShortcut
        ) -> Bool {
            guard shortcutContext.overlaps(proposedAction.shortcutContext) else {
                return false
            }
            return KeyboardShortcutSettings.shortcutsConflict(
                proposedShortcut,
                proposedUsesNumberedDigitMatching: proposedAction.usesNumberedDigitMatching,
                configuredShortcut,
                configuredUsesNumberedDigitMatching: usesNumberedDigitMatching
            )
        }

        func normalizedRecordedShortcutResult(_ shortcut: StoredShortcut) -> RecordedShortcutResolution {
            if shortcut.isUnbound {
                return .accepted(.unbound)
            }

            if let conflictingAction = KeyboardShortcutSettings.conflictingAction(
                for: shortcut,
                excluding: self
            ) {
                return .rejected(.conflictsWithAction(conflictingAction))
            }

            return resolvedRecordedShortcutIgnoringConflicts(shortcut)
        }

        func normalizedSettingsFileShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
            // cmux.json can load while the global settings store is still initializing.
            // Keep this path free of conflict and hotkey checks that consult global shortcut state.
            if shortcut.isUnbound {
                return .unbound
            }

            if case let .accepted(normalized) = resolvedRecordedShortcutIgnoringConflicts(
                shortcut,
                checkingSystemWideConflicts: false
            ) {
                return normalized
            }

            // Preserve invalid settings-file values for the show/hide hotkey so managed
            // configuration remains visible instead of silently falling back to defaults.
            // Runtime registration still rejects unsupported Carbon hotkey shapes.
            if usesNumberedDigitMatching || self == .globalSearch {
                return nil
            }
            return shortcut
        }

        func resolvedRecordedShortcutIgnoringConflicts(_ shortcut: StoredShortcut, checkingSystemWideConflicts: Bool = true) -> RecordedShortcutResolution {
            if shortcut.isUnbound {
                return .accepted(.unbound)
            }

            switch self {
            case .showHideAllWindows, .globalSearch:
                return KeyboardShortcutSettings.normalizedSystemWideHotkeyShortcutResult(
                    shortcut,
                    for: self,
                    checkingConflicts: checkingSystemWideConflicts
                )
            case .selectSurfaceByNumber, .selectWorkspaceByNumber:
                return resolvedNumberedDigitShortcut(shortcut)
            default:
                return .accepted(shortcut)
            }
        }

        private func resolvedNumberedDigitShortcut(
            _ shortcut: StoredShortcut
        ) -> RecordedShortcutResolution {
            let digitSource = shortcut.secondStroke ?? shortcut.firstStroke
            guard let digit = Int(digitSource.key), (1...9).contains(digit) else {
                return .rejected(.numberedShortcutRequiresDigit)
            }
            var normalized = shortcut
            if shortcut.hasChord {
                normalized.chordKey = "1"
            } else {
                normalized.key = "1"
            }
            return .accepted(normalized)
        }

        func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
            guard case let .accepted(normalized) = normalizedRecordedShortcutResult(shortcut) else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizedSystemWideHotkeyShortcutResult(
        _ shortcut: StoredShortcut,
        for action: Action,
        checkingConflicts: Bool = true
    ) -> RecordedShortcutResolution {
        guard !shortcut.hasChord else {
            return .rejected(.reservedBySystem)
        }
        guard shortcut.hasPrimaryModifier else {
            return .rejected(.systemWideHotkeyRequiresModifier)
        }
        guard shortcut.carbonHotKeyRegistration != nil,
              !checkingConflicts || !systemWideHotkeyConflicts(with: shortcut, excluding: action) else {
            return .rejected(.reservedBySystem)
        }
        return .accepted(shortcut)
    }

    private static func normalizedSystemWideHotkeyShortcut(_ shortcut: StoredShortcut, for action: Action) -> StoredShortcut? {
        guard case let .accepted(normalized) = normalizedSystemWideHotkeyShortcutResult(shortcut, for: action) else {
            return nil
        }
        return normalized
    }

    private static func systemWideHotkeyConflicts(with shortcut: StoredShortcut, excluding action: Action) -> Bool {
        guard let registration = shortcut.carbonHotKeyRegistration else { return false }
        let keyCode = UInt16(registration.keyCode)
        let modifierFlags = shortcut.modifierFlags
        // Validate against the keystroke AppKit shortcuts would see for the
        // registered Carbon hotkey under the current input source.
        let eventCharacter = KeyboardLayout.character(forKeyCode: keyCode)

        return reservedSystemWideHotkeyShortcuts(excluding: action).contains { reserved in
            reserved.matches(
                keyCode: keyCode,
                modifierFlags: modifierFlags,
                eventCharacter: eventCharacter
            )
        }
    }

    private static func reservedSystemWideHotkeyShortcuts(excluding currentAction: Action) -> [StoredShortcut] {
        var reserved: [StoredShortcut] = []

        for action in Action.allCases where action != currentAction {
            let shortcut = systemWideConflictShortcut(for: action)
            guard !shortcut.isUnbound else { continue }
            if shortcut.hasChord {
                reserved.append(StoredShortcut(first: shortcut.firstStroke))
                continue
            }
            if action.usesNumberedDigitMatching {
                let stroke = shortcut.firstStroke
                reserved.append(
                    contentsOf: (1...9).map { digit in
                        StoredShortcut(
                            key: String(digit),
                            command: stroke.command,
                            shift: stroke.shift,
                            option: stroke.option,
                            control: stroke.control
                        )
                    }
                )
                continue
            }
            reserved.append(shortcut)
        }

        reserved.append(contentsOf: hardcodedSystemWideHotkeyConflicts)
        return reserved
    }

    private static func systemWideConflictShortcut(for action: Action) -> StoredShortcut {
        switch action {
        case .showHideAllWindows:
            return SystemWideHotkeySettings.shortcut()
        default:
            return KeyboardShortcutSettings.shortcut(for: action)
        }
    }

    private static let hardcodedSystemWideHotkeyConflicts: [StoredShortcut] = [
        StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true),
        StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true),
        StoredShortcut(key: "`", command: true, shift: false, option: false, control: false),
        StoredShortcut(key: "`", command: true, shift: true, option: false, control: false),
        // Cmd+. is AppKit's standard cancel keystroke for modal alerts and
        // open/save panels. Refuse to register it as the global hotkey so the
        // first instinctive "cancel" press never hides the whole app.
        StoredShortcut(key: ".", command: true, shift: false, option: false, control: false),
    ]

    private static func conflictingAction(
        for proposedShortcut: StoredShortcut,
        excluding currentAction: Action
    ) -> Action? {
        for action in Action.allCases where action != currentAction {
            let configuredShortcut = shortcut(for: action)
            if action.conflicts(
                with: proposedShortcut,
                proposedAction: currentAction,
                configuredShortcut: configuredShortcut
            ) {
                return action
            }
        }
        return nil
    }

    private enum ShortcutConflictMatchMode {
        case exact
        case numberedDigitFamily
    }

    private static func shortcutsConflict(
        _ proposedShortcut: StoredShortcut,
        proposedUsesNumberedDigitMatching: Bool,
        _ configuredShortcut: StoredShortcut,
        configuredUsesNumberedDigitMatching: Bool
    ) -> Bool {
        guard !proposedShortcut.isUnbound, !configuredShortcut.isUnbound else {
            return false
        }

        switch (proposedShortcut.hasChord, configuredShortcut.hasChord) {
        case (false, false):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredShortcut.firstStroke,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (true, true):
            guard strokesConflict(proposedShortcut.firstStroke, configuredShortcut.firstStroke),
                  let proposedSecond = proposedShortcut.secondStroke,
                  let configuredSecond = configuredShortcut.secondStroke else {
                return false
            }
            return shortcutStrokeMatchersConflict(
                proposedSecond,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredSecond,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (true, false):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: .exact,
                configuredShortcut.firstStroke,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (false, true):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredShortcut.firstStroke,
                mode: .exact
            )
        }
    }

    private static func shortcutStrokeMatchersConflict(
        _ lhs: ShortcutStroke,
        mode lhsMode: ShortcutConflictMatchMode,
        _ rhs: ShortcutStroke,
        mode rhsMode: ShortcutConflictMatchMode
    ) -> Bool {
        switch (lhsMode, rhsMode) {
        case (.exact, .exact):
            return strokesConflict(lhs, rhs)
        case (.numberedDigitFamily, .numberedDigitFamily):
            return numberedDigitStrokeConflict(lhs, rhs)
        case (.numberedDigitFamily, .exact):
            return numberedDigitStrokeConflictsWithExactStroke(lhs, rhs)
        case (.exact, .numberedDigitFamily):
            return numberedDigitStrokeConflictsWithExactStroke(rhs, lhs)
        }
    }

    private static func numberedDigitStrokeConflictsWithExactStroke(
        _ numberedStroke: ShortcutStroke,
        _ exactStroke: ShortcutStroke
    ) -> Bool {
        guard isNumberedDigitStroke(numberedStroke), isNumberedDigitStroke(exactStroke) else {
            return false
        }
        return numberedStroke.command == exactStroke.command &&
            numberedStroke.shift == exactStroke.shift &&
            numberedStroke.option == exactStroke.option &&
            numberedStroke.control == exactStroke.control
    }

    private static func numberedDigitStrokeConflict(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        guard isNumberedDigitStroke(lhs), isNumberedDigitStroke(rhs) else { return false }
        return lhs.command == rhs.command &&
            lhs.shift == rhs.shift &&
            lhs.option == rhs.option &&
            lhs.control == rhs.control
    }

    private static func isNumberedDigitStroke(_ stroke: ShortcutStroke) -> Bool {
        guard let digit = Int(stroke.key) else { return false }
        return (1...9).contains(digit)
    }

    private static func strokesConflict(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        lhs.key == rhs.key &&
            lhs.command == rhs.command &&
            lhs.shift == rhs.shift &&
            lhs.option == rhs.option &&
            lhs.control == rhs.control
    }

}
