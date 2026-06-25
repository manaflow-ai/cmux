import AppKit
import Bonsplit
import Carbon
import CmuxBrowser
import CmuxSettings
import CmuxSettingsUI
import CmuxShortcuts
import CmuxWindowing
import CmuxWorkspaces
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
    static let actionUserInfoKey = "action"
    static let settingsFileDisplayPath = "~/.config/cmux/cmux.json"
    static var settingsFileStore: KeyboardShortcutSettingsFileStore = .shared {
        didSet { notifySettingsFileDidChange() }
    }
    #if DEBUG
    static var shortcutLookupObserver: ((Action) -> Void)?
    #endif

    static var publicShortcutActions: [Action] {
        Action.allCases.filter(\.isPublicShortcutAction)
    }

    static var settingsVisibleActions: [Action] {
        orderedSettingsVisibleActions(
            from: publicShortcutActions.filter { $0 != .showHideAllWindows }
        )
    }

    /// Opens the cmux settings file (`~/.config/cmux/cmux.json`) in the user's
    /// preferred editor, materializing the template through ``settingsFileStore``
    /// first when the file is absent, then routing the resolved URL through
    /// `PreferredEditorService` (honoring `preferredEditorCommand`, with an
    /// OS-default fallback). Scoped onto this type because it owns the settings
    /// file store and its on-disk location; replaces the retired top-level
    /// `openCmuxSettingsFileInEditor()` free function.
    @MainActor
    static func openSettingsFileInEditor() {
        let url = settingsFileStore.settingsFileURLForEditing()
        PreferredEditorService(defaults: .standard).open(url)
    }

    private static func orderedSettingsVisibleActions(from actions: [Action]) -> [Action] {
        let colocatedSidebarActions = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
        ].filter(actions.contains)
        let actionSet = Set(colocatedSidebarActions)
        let baseActions = actions.filter { !actionSet.contains($0) }

        guard let anchorIndex = baseActions.firstIndex(of: .markOldestUnreadAndJumpNext)
            ?? baseActions.firstIndex(of: .jumpToUnread) else {
            return colocatedSidebarActions + baseActions
        }

        var orderedActions = baseActions
        orderedActions.insert(contentsOf: colocatedSidebarActions, at: anchorIndex + 1)
        return orderedActions
    }

    enum ShortcutRecordingRejection: Equatable {
        case bareKeyNotAllowed
        case conflictsWithAction(Action)
        case reservedBySystem
        case numberedShortcutRequiresDigit
        case systemWideHotkeyRequiresModifier
    }

    enum RecordedShortcutResolution: Equatable {
        case accepted(StoredShortcut)
        case rejected(ShortcutRecordingRejection)
    }

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
        case clearScreenKeepScrollback

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

        // Canvas layout
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

        // File Explorer
        case toggleRightSidebar = "toggleFileExplorer"

        // Panels
        case saveFilePreview
        case openBrowser
        case focusBrowserAddressBar
        case browserBack
        case browserForward
        case browserReload
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
            case .newBrowserWorkspace: return String(localized: "shortcut.newBrowserWorkspace.label", defaultValue: "New Browser Workspace")
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
            case .clearScreenKeepScrollback: return String(localized: "shortcut.clearScreenKeepScrollback.label", defaultValue: "Clear Screen (Keep Scrollback)")
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
            case .toggleCanvasLayout: return String(localized: "shortcut.toggleCanvasLayout.label", defaultValue: "Toggle Canvas Layout")
            case .canvasRevealFocusedPane: return String(localized: "shortcut.canvasRevealFocusedPane.label", defaultValue: "Canvas: Reveal Focused Pane")
            case .canvasOverview: return String(localized: "shortcut.canvasOverview.label", defaultValue: "Canvas: Toggle Overview")
            case .canvasZoomIn: return String(localized: "shortcut.canvasZoomIn.label", defaultValue: "Canvas: Zoom In")
            case .canvasZoomOut: return String(localized: "shortcut.canvasZoomOut.label", defaultValue: "Canvas: Zoom Out")
            case .canvasZoomReset: return String(localized: "shortcut.canvasZoomReset.label", defaultValue: "Canvas: Actual Size")
            case .canvasTidy: return String(localized: "shortcut.canvasTidy.label", defaultValue: "Canvas: Tidy Panes")
            case .canvasAlignLeft: return String(localized: "shortcut.canvasAlignLeft.label", defaultValue: "Canvas: Align Left Edges")
            case .canvasAlignRight: return String(localized: "shortcut.canvasAlignRight.label", defaultValue: "Canvas: Align Right Edges")
            case .canvasAlignTop: return String(localized: "shortcut.canvasAlignTop.label", defaultValue: "Canvas: Align Top Edges")
            case .canvasAlignBottom: return String(localized: "shortcut.canvasAlignBottom.label", defaultValue: "Canvas: Align Bottom Edges")
            case .canvasEqualizeWidths: return String(localized: "shortcut.canvasEqualizeWidths.label", defaultValue: "Canvas: Equalize Widths")
            case .canvasEqualizeHeights: return String(localized: "shortcut.canvasEqualizeHeights.label", defaultValue: "Canvas: Equalize Heights")
            case .canvasDistributeHorizontally: return String(localized: "shortcut.canvasDistributeHorizontally.label", defaultValue: "Canvas: Distribute Horizontally")
            case .canvasDistributeVertically: return String(localized: "shortcut.canvasDistributeVertically.label", defaultValue: "Canvas: Distribute Vertically")
            case .toggleRightSidebar: return String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar")
            case .saveFilePreview: return String(localized: "shortcut.saveFilePreview.label", defaultValue: "Save File Preview")
            case .openBrowser: return String(localized: "shortcut.openBrowser.label", defaultValue: "Open Browser")
            case .focusBrowserAddressBar: return String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")
            case .browserBack: return String(localized: "menu.view.back", defaultValue: "Back")
            case .browserForward: return String(localized: "menu.view.forward", defaultValue: "Forward")
            case .browserReload: return String(localized: "menu.view.reloadPage", defaultValue: "Reload Page")
            case .browserHardReload: return String(localized: "menu.view.hardRefresh", defaultValue: "Hard Refresh")
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
            case .newBrowserWorkspace:
                // Option+Cmd+N: sits next to New Workspace (Cmd+N) and New Window
                // (Cmd+Shift+N) without colliding with any cmux default or an
                // AppKit-reserved keystroke.
                return StoredShortcut(key: "n", command: true, shift: false, option: true, control: false)
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
            case .toggleCanvasLayout:
                return StoredShortcut(key: "c", command: true, shift: false, option: false, control: true)
            case .canvasRevealFocusedPane:
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: true)
            case .canvasOverview:
                return StoredShortcut(key: "o", command: true, shift: false, option: false, control: true)
            case .canvasZoomIn:
                return StoredShortcut(key: "=", command: true, shift: false, option: true, control: false)
            case .canvasZoomOut:
                return StoredShortcut(key: "-", command: true, shift: false, option: true, control: false)
            case .canvasZoomReset:
                return StoredShortcut(key: "0", command: true, shift: false, option: true, control: false)
            case .canvasTidy:
                return StoredShortcut(key: "t", command: true, shift: false, option: false, control: true)
            case .canvasAlignLeft,
                 .canvasAlignRight,
                 .canvasAlignTop,
                 .canvasAlignBottom,
                 .canvasEqualizeWidths,
                 .canvasEqualizeHeights,
                 .canvasDistributeHorizontally,
                 .canvasDistributeVertically:
                // Unbound by default: reachable through the command palette and
                // the canvas.* socket verbs; users opt into keys via Settings.
                return .unbound
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
            case .clearScreenKeepScrollback:
                // Cmd+Shift+K: the less-destructive sibling of Ghostty's Cmd+K
                // (clear_screen), which also wipes scrollback. Shift+K is unbound in
                // both Ghostty defaults and cmux, and sits next to the full-clear
                // chord. Rebindable in Settings → Keyboard Shortcuts.
                return StoredShortcut(key: "k", command: true, shift: true, option: false, control: false)
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
            case .browserHardReload:
                return StoredShortcut(key: "r", command: true, shift: true, option: false, control: false)
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
            // Two bindings on the same keystroke only collide when some focus
            // state activates both AND router priority cannot decide the overlap.
            // A `shortcuts.when` override (or the built-in context default) can
            // make them non-overlapping — e.g. ⌃1 selecting a workspace only when
            // the sidebar is NOT focused coexists with the sidebar's ⌃1 (issue
            // #5189) — and a pre-routed action (sidebar modes) wins its context
            // outright, so the factory Select Surface ⌃1…9 coexists with the
            // sidebar's ⌃1…5 by priority.
            guard ShortcutWhenClause.bindingsCollide(
                KeyboardShortcutSettings.effectiveWhenClause(for: self),
                lhsHasPriority: hasPriorityShortcutRouting,
                KeyboardShortcutSettings.effectiveWhenClause(for: proposedAction),
                rhsHasPriority: proposedAction.hasPriorityShortcutRouting
            ) else {
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

    private static func storedShortcutForPersistence(
        _ shortcut: StoredShortcut,
        action: Action
    ) -> StoredShortcut? {
        if shortcut.isUnbound {
            return shortcut
        }

        switch action.resolvedRecordedShortcutIgnoringConflicts(shortcut) {
        case let .accepted(normalizedShortcut):
            return normalizedShortcut
        case .rejected:
            if action.usesNumberedDigitMatching || action == .showHideAllWindows || action == .globalSearch {
                return nil
            }
            return shortcut
        }
    }

    private static func storedShortcutForReplacement(
        _ shortcut: StoredShortcut,
        action: Action
    ) -> StoredShortcut? {
        switch action.resolvedRecordedShortcutIgnoringConflicts(shortcut) {
        case let .accepted(normalizedShortcut):
            return normalizedShortcut
        case .rejected:
            return nil
        }
    }

    private static func persistShortcut(
        _ shortcut: StoredShortcut,
        for action: Action,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: action.defaultsKey)
    }

    static func setShortcut(_ shortcut: StoredShortcut, for action: Action) {
        guard !isManagedBySettingsFile(action) else { return }

        guard let storedShortcut = storedShortcutForPersistence(shortcut, action: action) else {
            return
        }

        persistShortcut(storedShortcut, for: action)
        postDidChangeNotification(action: action)
    }

    static func swapShortcutConflict(
        proposedShortcut: StoredShortcut,
        currentAction: Action,
        conflictingAction: Action,
        previousShortcut: StoredShortcut
    ) -> Bool {
        guard !isManagedBySettingsFile(currentAction),
              !isManagedBySettingsFile(conflictingAction),
              conflictingAction.conflicts(with: proposedShortcut, proposedAction: currentAction, configuredShortcut: shortcut(for: conflictingAction)),
              let resolvedCurrentShortcut = storedShortcutForReplacement(
                proposedShortcut,
                action: currentAction
            ),
            let resolvedConflictingShortcut = storedShortcutForReplacement(
                previousShortcut,
                action: conflictingAction
            )
        else {
            return false
        }

        persistShortcut(resolvedCurrentShortcut, for: currentAction)
        persistShortcut(resolvedConflictingShortcut, for: conflictingAction)
        postDidChangeNotification(action: currentAction)
        postDidChangeNotification(action: conflictingAction)
        return true
    }

    static func notifySettingsFileDidChange(center: NotificationCenter = .default) { postDidChangeNotification(center: center) }

    static func resetShortcut(for action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        postDidChangeNotification(action: action)
    }

    static func clearShortcut(for action: Action) { setShortcut(.unbound, for: action) }

    static func resetAll() {
        for action in Action.allCases {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        postDidChangeNotification()
    }

    private static func postDidChangeNotification(
        action: Action? = nil,
        center: NotificationCenter = .default
    ) {
        var userInfo: [AnyHashable: Any] = [:]
        if let action {
            userInfo[actionUserInfoKey] = action.rawValue
        }
        center.post(
            name: didChangeNotification,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }

    // MARK: - Backwards-Compatible API (call-sites can migrate gradually)

    // Keys (used by debug socket command + UI tests)
    static let focusLeftKey = Action.focusLeft.defaultsKey
    static let focusRightKey = Action.focusRight.defaultsKey
    static let focusUpKey = Action.focusUp.defaultsKey
    static let focusDownKey = Action.focusDown.defaultsKey

    // Defaults (used by settings reset + recorder button initial title)
    static let showNotificationsDefault = Action.showNotifications.defaultShortcut
    static let jumpToUnreadDefault = Action.jumpToUnread.defaultShortcut

    static func showNotificationsShortcut() -> StoredShortcut { shortcut(for: .showNotifications) }
    static func setShowNotificationsShortcut(_ shortcut: StoredShortcut) { setShortcut(shortcut, for: .showNotifications) }

    static func jumpToUnreadShortcut() -> StoredShortcut { shortcut(for: .jumpToUnread) }
    static func setJumpToUnreadShortcut(_ shortcut: StoredShortcut) { setShortcut(shortcut, for: .jumpToUnread) }

    static func nextSidebarTabShortcut() -> StoredShortcut { shortcut(for: .nextSidebarTab) }
    static func prevSidebarTabShortcut() -> StoredShortcut { shortcut(for: .prevSidebarTab) }
    static func renameWorkspaceShortcut() -> StoredShortcut { shortcut(for: .renameWorkspace) }
    static func closeWorkspaceShortcut() -> StoredShortcut { shortcut(for: .closeWorkspace) }

    static func focusLeftShortcut() -> StoredShortcut { shortcut(for: .focusLeft) }
    static func focusRightShortcut() -> StoredShortcut { shortcut(for: .focusRight) }
    static func focusUpShortcut() -> StoredShortcut { shortcut(for: .focusUp) }
    static func focusDownShortcut() -> StoredShortcut { shortcut(for: .focusDown) }

    static func splitRightShortcut() -> StoredShortcut { shortcut(for: .splitRight) }
    static func splitDownShortcut() -> StoredShortcut { shortcut(for: .splitDown) }
    static func toggleSplitZoomShortcut() -> StoredShortcut { shortcut(for: .toggleSplitZoom) }
    static func splitBrowserRightShortcut() -> StoredShortcut { shortcut(for: .splitBrowserRight) }
    static func splitBrowserDownShortcut() -> StoredShortcut { shortcut(for: .splitBrowserDown) }

    static func nextSurfaceShortcut() -> StoredShortcut { shortcut(for: .nextSurface) }
    static func prevSurfaceShortcut() -> StoredShortcut { shortcut(for: .prevSurface) }
    static func selectSurfaceByNumberShortcut() -> StoredShortcut { shortcut(for: .selectSurfaceByNumber) }
    static func newSurfaceShortcut() -> StoredShortcut { shortcut(for: .newSurface) }
    static func selectWorkspaceByNumberShortcut() -> StoredShortcut { shortcut(for: .selectWorkspaceByNumber) }
    static func focusTextBoxInputShortcut() -> StoredShortcut { shortcut(for: .focusTextBoxInput) }
    static func attachTextBoxFileShortcut() -> StoredShortcut { shortcut(for: .attachTextBoxFile) }

    static func openBrowserShortcut() -> StoredShortcut { shortcut(for: .openBrowser) }
    static func toggleBrowserDeveloperToolsShortcut() -> StoredShortcut { shortcut(for: .toggleBrowserDeveloperTools) }
    static func showBrowserJavaScriptConsoleShortcut() -> StoredShortcut { shortcut(for: .showBrowserJavaScriptConsole) }
}

enum SystemWideHotkeySettings {
    static let enabledKey = "systemWideHotkey.enabled"
    static let legacyShortcutKey = "systemWideHotkey.shortcut"
    static let defaultEnabled = false
    static let action: KeyboardShortcutSettings.Action = .showHideAllWindows

    static var defaultShortcut: StoredShortcut { action.defaultShortcut }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func shortcut() -> StoredShortcut {
        migrateLegacyShortcutIfNeeded()
        if let managedShortcut = KeyboardShortcutSettings.settingsFileStore.override(for: action) {
            return managedShortcut
        }
        return storedShortcut() ?? defaultShortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut) {
        migrateLegacyShortcutIfNeeded()
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
    }

    static func normalizedRecordedShortcutResult(
        _ shortcut: StoredShortcut
    ) -> KeyboardShortcutSettings.RecordedShortcutResolution {
        action.normalizedRecordedShortcutResult(shortcut)
    }

    static func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
        action.normalizedRecordedShortcut(shortcut)
    }

    static func isManagedBySettingsFile() -> Bool {
        KeyboardShortcutSettings.isManagedBySettingsFile(action)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: legacyShortcutKey)
        defaults.removeObject(forKey: action.defaultsKey)
    }

    private static func migrateLegacyShortcutIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: legacyShortcutKey) != nil else { return }
        defer { defaults.removeObject(forKey: legacyShortcutKey) }

        guard defaults.object(forKey: action.defaultsKey) == nil,
              let data = defaults.data(forKey: legacyShortcutKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return
        }

        let migratedShortcut = normalizedRecordedShortcut(shortcut) ?? shortcut
        guard let migratedData = try? JSONEncoder().encode(migratedShortcut) else { return }
        defaults.set(migratedData, forKey: action.defaultsKey)
    }

    private static func storedShortcut(defaults: UserDefaults = .standard) -> StoredShortcut? {
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return KeyboardShortcutSettings.settingsFileStore.override(for: action)
        }
        return shortcut
    }
}

struct CarbonHotKeyRegistration: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}

final class SystemWideHotkeyController {
    private static let hotKeySignature: OSType = 0x434D484B // "CMHK"
    private static let hotKeyIDs: [KeyboardShortcutSettings.Action: UInt32] = [
        .showHideAllWindows: 1,
        .globalSearch: 2,
    ]
    private static let systemWideActions: [KeyboardShortcutSettings.Action] = [
        .showHideAllWindows,
        .globalSearch,
    ]

    private var hotKeyRefs: [KeyboardShortcutSettings.Action: EventHotKeyRef] = [:]
    private var hotKeyHandler: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?
    private var recorderObserver: NSObjectProtocol?
    private var packageRecorderObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var registeredShortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var registeredHotKeyRegistrations: [KeyboardShortcutSettings.Action: CarbonHotKeyRegistration] = [:]

    init() {}

    func start() {
        guard defaultsObserver == nil else { return }

        installHotKeyHandlerIfNeeded()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        recorderObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutRecorderActivity.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        // The live Settings UI uses the CmuxSettingsUI package recorder, which
        // signals arm/disarm through its own notification (it cannot post the
        // app-target `KeyboardShortcutRecorderActivity` one). Without this,
        // recording a system-wide hotkey in Settings would not unregister the
        // existing Carbon hotkey, so the keystroke would fire the global action
        // instead of being captured (issue #5189).
        packageRecorderObserver = NotificationCenter.default.addObserver(
            forName: RecorderHostButton.activeRecordingDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        appHideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureHiddenWindowRestoreTargets()
            }
        }

        refreshRegistration()
    }

    private func refreshRegistration() {
        // Stand down while either recorder is armed (legacy app-target recorder
        // or the CmuxSettingsUI package recorder) so a system-wide hotkey being
        // rebound in Settings is captured rather than fired.
        let isShortcutRecordingActive = KeyboardShortcutRecorderActivity.isAnyRecorderActive
            || RecorderHostButton.isActivelyRecording

        guard !isShortcutRecordingActive else {
            unregisterHotKeys()
            return
        }

        for action in Self.systemWideActions {
            refreshRegistration(for: action)
        }
    }

    private func refreshRegistration(for action: KeyboardShortcutSettings.Action) {
        let configuredShortcut = shortcut(for: action)
        guard isSystemWideActionEnabled(action, shortcut: configuredShortcut) else {
            unregisterHotKey(for: action)
            return
        }

        guard let normalizedShortcut = action.normalizedRecordedShortcut(configuredShortcut),
              let registration = normalizedShortcut.carbonHotKeyRegistration else {
            unregisterHotKey(for: action)
            return
        }

        if registeredShortcuts[action] == normalizedShortcut,
           registeredHotKeyRegistrations[action] == registration,
           hotKeyRefs[action] != nil {
            return
        }

        unregisterHotKey(for: action)
        installHotKeyHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID(for: action))
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            registration.keyCode,
            registration.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
#if DEBUG
            cmuxDebugLog(
                "globalHotkey.register failed action=\(action.rawValue) shortcut=\(normalizedShortcut.displayString) " +
                "keyCode=\(registration.keyCode) modifiers=\(registration.modifiers) status=\(status)"
            )
#endif
            return
        }

        hotKeyRefs[action] = hotKeyRef
        registeredShortcuts[action] = normalizedShortcut
        registeredHotKeyRegistrations[action] = registration

#if DEBUG
        cmuxDebugLog(
            "globalHotkey.register success action=\(action.rawValue) shortcut=\(normalizedShortcut.displayString) " +
            "keyCode=\(registration.keyCode) modifiers=\(registration.modifiers)"
        )
#endif
    }

    private func shortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        switch action {
        case .showHideAllWindows:
            return SystemWideHotkeySettings.shortcut()
        default:
            return KeyboardShortcutSettings.shortcut(for: action)
        }
    }

    private func isSystemWideActionEnabled(
        _ action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut
    ) -> Bool {
        guard !shortcut.isUnbound else { return false }
        switch action {
        case .showHideAllWindows:
            return SystemWideHotkeySettings.isEnabled()
        case .globalSearch:
            return true
        default:
            assertionFailure("Unhandled system-wide hotkey action: \(action.rawValue)")
            return false
        }
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            userInfo,
            &hotKeyHandler
        )

#if DEBUG
        if status != noErr {
            cmuxDebugLog("globalHotkey.handlerInstall failed status=\(status)")
        }
#endif
    }

    private func unregisterHotKey(for action: KeyboardShortcutSettings.Action) {
        if let hotKeyRef = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(hotKeyRef)
        }
        registeredShortcuts[action] = nil
        registeredHotKeyRegistrations[action] = nil
    }

    private func unregisterHotKeys() {
        for action in Self.systemWideActions {
            unregisterHotKey(for: action)
        }
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userInfo in
        guard let userInfo else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<SystemWideHotkeyController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return controller.handleHotKeyEvent(event)
    }

    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == Self.hotKeySignature,
              let action = Self.action(forHotKeyID: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

#if DEBUG
        let shortcut = registeredShortcuts[action]?.displayString ?? "unknown"
        cmuxDebugLog("globalHotkey.fire action=\(action.rawValue) shortcut=\(shortcut) active=\(NSApp.isActive ? 1 : 0)")
#endif

        Task { @MainActor [weak self] in
            self?.perform(action)
        }
        return OSStatus(noErr)
    }

    @MainActor
    private func perform(_ action: KeyboardShortcutSettings.Action) {
        switch action {
        case .showHideAllWindows:
            AppDelegate.shared?.toggleApplicationVisibilityFromGlobalHotkey()
        case .globalSearch:
            AppDelegate.shared?.toggleGlobalSearchPaletteFromGlobalHotkey()
        default:
            assertionFailure("Unhandled system-wide hotkey action: \(action.rawValue)")
            break
        }
    }

    @MainActor
    private func captureHiddenWindowRestoreTargets() {
        AppDelegate.shared?.captureMainWindowVisibilityRestoreTargetsForApplicationHide()
    }

    private static func hotKeyID(for action: KeyboardShortcutSettings.Action) -> UInt32 {
        guard let hotKeyID = hotKeyIDs[action] else {
            assertionFailure("Unhandled system-wide hotkey action: \(action.rawValue)")
            return 0
        }
        return hotKeyID
    }

    private static func action(forHotKeyID hotKeyID: UInt32) -> KeyboardShortcutSettings.Action? {
        systemWideActions.first { Self.hotKeyID(for: $0) == hotKeyID }
    }
}

struct ShortcutStroke: Equatable, Hashable {
    enum RecordingResult: Equatable {
        case accepted(ShortcutStroke)
        case rejected(KeyboardShortcutSettings.ShortcutRecordingRejection)
        case unsupportedKey
    }

    private typealias RecordableKey = ShortcutKeyTable.RecordableKey

    /// The pure key-code/character mapping tables this stroke forwards its
    /// recording and matching lookups into. Stateless value; one shared instance
    /// since `ShortcutStroke`'s table accessors are `static`.
    private static let keyTable = ShortcutKeyTable()

    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var keyCode: UInt16?

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
    }

    var displayString: String {
        ShortcutDisplayFormatter().strokeDisplayString(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    var modifierDisplayString: String {
        ShortcutDisplayFormatter().modifierDisplayString(
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    var keyDisplayString: String {
        ShortcutDisplayFormatter().keyDisplayString(key)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var hasPrimaryModifier: Bool {
        command || option || control
    }

    var keyEquivalent: KeyEquivalent? {
        if key == "space" { return KeyEquivalent(Character(" ")) }

        if Self.keyTable.usesDirectKeyCodeMatching(key) {
            return nil
        }

        switch key {
        case "←":
            return .leftArrow
        case "→":
            return .rightArrow
        case "↑":
            return .upArrow
        case "↓":
            return .downArrow
        case "\t":
            return .tab
        case "\r":
            return KeyEquivalent(Character("\r"))
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1, let character = lowered.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var modifiers: SwiftUI.EventModifiers = []
        if command {
            modifiers.insert(.command)
        }
        if shift {
            modifiers.insert(.shift)
        }
        if option {
            modifiers.insert(.option)
        }
        if control {
            modifiers.insert(.control)
        }
        return modifiers
    }

    var menuItemKeyEquivalent: String? {
        if key == "space" { return " " }

        if Self.keyTable.usesDirectKeyCodeMatching(key) {
            return nil
        }

        switch key {
        case "←":
            guard let scalar = UnicodeScalar(NSLeftArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "→":
            guard let scalar = UnicodeScalar(NSRightArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↑":
            guard let scalar = UnicodeScalar(NSUpArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↓":
            guard let scalar = UnicodeScalar(NSDownArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "\t":
            return "\t"
        case "\r":
            return "\r"
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    static func isEscapeCancelEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }

        if event.keyCode == 53 {
            return true
        }

        let escapeScalar = UnicodeScalar(0x1B)!
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let shouldTreatEscapeCharacterAsCancel = normalizedFlags.isEmpty || event.keyCode == 36 || event.keyCode == 76

        if shouldTreatEscapeCharacterAsCancel,
           event.characters?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        if shouldTreatEscapeCharacterAsCancel,
           event.charactersIgnoringModifiers?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        return false
    }

    static func from(event: NSEvent, requireModifier: Bool = true) -> ShortcutStroke? {
        guard case let .accepted(stroke) = recordingResult(from: event, requireModifier: requireModifier) else {
            return nil
        }
        return stroke
    }

    static func recordingResult(
        from event: NSEvent,
        requireModifier: Bool = true
    ) -> RecordingResult {
        guard !isEscapeCancelEvent(event),
              let recordableKey = recordableKey(from: event) else {
            return .unsupportedKey
        }

        let flags = normalizedModifierFlags(from: event.modifierFlags)

        let stroke = ShortcutStroke(
            key: recordableKey.key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            keyCode: recordableKey.keyCode
        )

        if requireModifier,
           !stroke.command && !stroke.shift && !stroke.option && !stroke.control &&
           !stroke.isBareShortcutAllowedWithoutModifier {
            return .rejected(.bareKeyNotAllowed)
        }
        return .accepted(stroke)
    }

    static func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    /// Whether this stroke matches the live key `event`.
    ///
    /// Forwards the pure `NSEvent`-vs-stroke predicate to
    /// ``CmuxShortcuts/ShortcutCoordinator/matchesStroke(event:strokeKey:strokeModifierFlags:strokeKeyCode:optionTextBypass:layoutCharacterProvider:)``,
    /// which now owns the matching ladder. The Option-printable-text bypass stays
    /// here because its layout translation is text-input mode (distinct from the
    /// coordinator's shortcut-mode provider). The seam is the coordinator's
    /// `nonisolated static` matcher, so this `nonisolated` predicate reaches the
    /// relocated ladder directly, with no coordinator instance and no actor hop.
    func matches(
        event: NSEvent,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        ShortcutCoordinator.matchesStroke(
            event: event,
            strokeKey: key,
            strokeModifierFlags: modifierFlags,
            strokeKeyCode: keyCode,
            optionTextBypass: shortcutRoutingShouldBypassForPrintableOptionText(event: event),
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    /// Whether this stroke matches an already-extracted key code, modifier flags,
    /// and produced character. Forwards the predicate ladder to
    /// ``CmuxShortcuts/ShortcutCoordinator/matchesStroke(strokeKey:strokeModifierFlags:strokeKeyCode:keyCode:modifierFlags:eventCharacter:layoutCharacterProvider:)``.
    func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        ShortcutCoordinator.matchesStroke(
            strokeKey: key,
            strokeModifierFlags: modifierFlags,
            strokeKeyCode: self.keyCode,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventCharacter: eventCharacter,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    private var isBareShortcutAllowedWithoutModifier: Bool {
        Self.keyTable.usesDirectKeyCodeMatching(key)
    }

    private static func recordableKey(from event: NSEvent) -> RecordableKey? {
        if event.type == .systemDefined {
            return mediaKey(from: event)
        }

        guard event.type == .keyDown || event.type == .keyUp else {
            return nil
        }

        if let specialKey = event.specialKey,
           let recordableKey = keyTable.recordableKey(from: specialKey, eventKeyCode: event.keyCode) {
            return recordableKey
        }

        guard let storedKey = keyTable.storedKey(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            return nil
        }
        return RecordableKey(key: storedKey, keyCode: event.keyCode)
    }

    private static func mediaKey(from event: NSEvent) -> RecordableKey? {
        guard event.type == .systemDefined else { return nil }
        return keyTable.mediaKey(
            systemDefinedSubtype: event.subtype.rawValue,
            data1: event.data1
        )
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if command { modifiers |= UInt32(cmdKey) }
        if shift { modifiers |= UInt32(shiftKey) }
        if option { modifiers |= UInt32(optionKey) }
        if control { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    func resolvedKeyCode(
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> UInt16? {
        if let keyCode {
            return keyCode
        }

        let shortcutKey = key.lowercased()
        let flags = modifierFlags
        let applyShiftNormalization = flags.contains(.shift)

        for candidateKeyCode in Self.keyTable.supportedShortcutKeyCodes {
            let candidateCharacter = layoutCharacterProvider(candidateKeyCode, flags)
            if Self.keyTable.shortcutCharacterMatches(
                eventCharacter: candidateCharacter,
                shortcutKey: shortcutKey,
                applyShiftSymbolNormalization: applyShiftNormalization,
                eventKeyCode: candidateKeyCode
            ) {
                return candidateKeyCode
            }
        }

        return Self.keyTable.keyCodeForShortcutKey(shortcutKey)
    }

    var carbonHotKeyRegistration: CarbonHotKeyRegistration? {
        guard let keyCode = resolvedKeyCode() else { return nil }
        return CarbonHotKeyRegistration(keyCode: UInt32(keyCode), modifiers: carbonModifiers)
    }
}

/// A keyboard shortcut that can be stored in UserDefaults
struct StoredShortcut: Codable, Equatable, Hashable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var keyCode: UInt16?
    var chordKey: String?
    var chordCommand: Bool
    var chordShift: Bool
    var chordOption: Bool
    var chordControl: Bool
    var chordKeyCode: UInt16?

    static var unbound: StoredShortcut {
        StoredShortcut(key: "", command: false, shift: false, option: false, control: false)
    }

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        keyCode: UInt16? = nil,
        chordKey: String? = nil,
        chordCommand: Bool = false,
        chordShift: Bool = false,
        chordOption: Bool = false,
        chordControl: Bool = false,
        chordKeyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
        self.chordKey = chordKey?.isEmpty == true ? nil : chordKey
        self.chordCommand = chordCommand
        self.chordShift = chordShift
        self.chordOption = chordOption
        self.chordControl = chordControl
        self.chordKeyCode = chordKeyCode
    }

    init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.init(
            key: first.key,
            command: first.command,
            shift: first.shift,
            option: first.option,
            control: first.control,
            keyCode: first.keyCode,
            chordKey: second?.key,
            chordCommand: second?.command ?? false,
            chordShift: second?.shift ?? false,
            chordOption: second?.option ?? false,
            chordControl: second?.control ?? false,
            chordKeyCode: second?.keyCode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case command
        case shift
        case option
        case control
        case keyCode
        case chordKey
        case chordCommand
        case chordShift
        case chordOption
        case chordControl
        case chordKeyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            command: try container.decode(Bool.self, forKey: .command),
            shift: try container.decode(Bool.self, forKey: .shift),
            option: try container.decode(Bool.self, forKey: .option),
            control: try container.decode(Bool.self, forKey: .control),
            keyCode: try container.decodeIfPresent(UInt16.self, forKey: .keyCode),
            chordKey: try container.decodeIfPresent(String.self, forKey: .chordKey),
            chordCommand: try container.decodeIfPresent(Bool.self, forKey: .chordCommand) ?? false,
            chordShift: try container.decodeIfPresent(Bool.self, forKey: .chordShift) ?? false,
            chordOption: try container.decodeIfPresent(Bool.self, forKey: .chordOption) ?? false,
            chordControl: try container.decodeIfPresent(Bool.self, forKey: .chordControl) ?? false,
            chordKeyCode: try container.decodeIfPresent(UInt16.self, forKey: .chordKeyCode)
        )
    }

    var isUnbound: Bool {
        key.isEmpty
    }

    var firstStroke: ShortcutStroke {
        ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }

    var secondStroke: ShortcutStroke? {
        guard let chordKey else { return nil }
        return ShortcutStroke(
            key: chordKey,
            command: chordCommand,
            shift: chordShift,
            option: chordOption,
            control: chordControl,
            keyCode: chordKeyCode
        )
    }

    var hasChord: Bool {
        secondStroke != nil
    }

    /// Whether the titlebar should surface this binding's shortcut hint.
    ///
    /// Forwards to ``CmuxSettings/StoredShortcut/titlebarHintShouldShow(alwaysShowShortcutHints:modifierPressed:)``,
    /// the single source of truth for the rule, after bridging this app-target
    /// binding into its persisted ``CmuxSettings/StoredShortcut`` form.
    func titlebarHintShouldShow(
        alwaysShowShortcutHints: Bool,
        modifierPressed: Bool
    ) -> Bool {
        cmuxSettingsStoredShortcut.titlebarHintShouldShow(
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: modifierPressed
        )
    }

    /// This binding as its persisted ``CmuxSettings/StoredShortcut`` value.
    var cmuxSettingsStoredShortcut: CmuxSettings.StoredShortcut {
        CmuxSettings.StoredShortcut(
            first: CmuxSettings.ShortcutStroke(
                key: key,
                command: command,
                shift: shift,
                option: option,
                control: control,
                keyCode: keyCode
            ),
            second: chordKey.map { chordKey in
                CmuxSettings.ShortcutStroke(
                    key: chordKey,
                    command: chordCommand,
                    shift: chordShift,
                    option: chordOption,
                    control: chordControl,
                    keyCode: chordKeyCode
                )
            }
        )
    }

    var displayString: String {
        if isUnbound {
            return String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        }
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.displayString)"
        }
        return firstStroke.displayString
    }

    var numberedDisplayString: String {
        if isUnbound {
            return displayString
        }
        if let secondStroke {
            if ShortcutDisplayFormatter().isNumberedDigitKey(secondStroke.key) {
                return numberedDigitHintPrefix + ShortcutDisplayFormatter().numberedDigitRangeHint
            }
            return displayString
        }
        if ShortcutDisplayFormatter().isNumberedDigitKey(firstStroke.key) {
            return firstStroke.modifierDisplayString + ShortcutDisplayFormatter().numberedDigitRangeHint
        }
        return displayString
    }

    var numberedDigitHintPrefix: String {
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.modifierDisplayString)"
        }
        return firstStroke.modifierDisplayString
    }

    var modifierDisplayString: String {
        firstStroke.modifierDisplayString
    }

    var keyDisplayString: String {
        firstStroke.keyDisplayString
    }

    var modifierFlags: NSEvent.ModifierFlags {
        firstStroke.modifierFlags
    }

    var hasPrimaryModifier: Bool {
        guard !isUnbound else { return false }
        return firstStroke.hasPrimaryModifier
    }

    var keyEquivalent: KeyEquivalent? {
        guard !isUnbound, !hasChord else { return nil }
        return firstStroke.keyEquivalent
    }

    var eventModifiers: SwiftUI.EventModifiers {
        firstStroke.eventModifiers
    }

    var menuItemKeyEquivalent: String? {
        guard !isUnbound, !hasChord else { return nil }
        return firstStroke.menuItemKeyEquivalent
    }

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let stroke = ShortcutStroke.from(event: event) else { return nil }
        return StoredShortcut(first: stroke)
    }

    func matches(
        event: NSEvent,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        guard !isUnbound, !hasChord else { return false }
        return firstStroke.matches(event: event, layoutCharacterProvider: layoutCharacterProvider)
    }

    func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        guard !isUnbound, !hasChord else { return false }
        return firstStroke.matches(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventCharacter: eventCharacter,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    var carbonHotKeyRegistration: CarbonHotKeyRegistration? {
        guard !isUnbound, !hasChord else { return nil }
        return firstStroke.carbonHotKeyRegistration
    }
}

/// The app↔package adapter that lets ``CmuxShortcuts/ShortcutCoordinator`` match
/// against the app-target ``ShortcutStroke``/``StoredShortcut`` value types it
/// cannot reference across the module boundary.
///
/// The matching ladder itself lives entirely in `CmuxShortcuts`
/// (``CmuxShortcuts/ShortcutCoordinator`` `+Matching`). These overloads decompose
/// the app-only stroke/shortcut into the value components the package matchers
/// take, supply the coordinator's injected layout-character provider, and compute
/// the Option-printable-text bypass at this app seam (its layout translation is
/// text-input mode, distinct from the coordinator's shortcut-mode provider).
extension ShortcutCoordinator {
    /// Whether `event` matches `stroke` as a normal-key shortcut.
    func matchesStroke(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        matchesStroke(
            event: event,
            strokeKey: stroke.key,
            strokeModifierFlags: stroke.modifierFlags,
            strokeKeyCode: stroke.keyCode,
            optionTextBypass: shortcutRoutingShouldBypassForPrintableOptionText(event: event),
            layoutCharacterProvider: layoutCharacter(forKeyCode:modifierFlags:)
        )
    }

    /// Whether `event` matches `shortcut`'s single stroke, skipping unbound or
    /// chorded shortcuts (which this single-stroke predicate does not handle).
    func matchesStroke(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.isUnbound, !shortcut.hasChord else { return false }
        return matchesStroke(event: event, stroke: shortcut.firstStroke)
    }

    /// The numbered digit (1–9) `stroke` matches for `event`, gated on the stroke's
    /// modifier flags.
    func numberedShortcutDigit(event: NSEvent, stroke: ShortcutStroke) -> Int? {
        numberedShortcutDigit(event: event, strokeModifierFlags: stroke.modifierFlags)
    }

    /// The numbered digit (1–9) `shortcut`'s single stroke matches, skipping
    /// unbound or chorded shortcuts.
    func numberedShortcutDigit(event: NSEvent, shortcut: StoredShortcut) -> Int? {
        guard !shortcut.isUnbound, !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    /// Whether `event` matches a Tab-key (key code 48) `stroke`.
    func matchesTabStroke(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        matchesTabStroke(event: event, strokeModifierFlags: stroke.modifierFlags)
    }

    /// Whether `event` matches a Tab-key `shortcut`'s single stroke, skipping
    /// chorded shortcuts.
    func matchesTabStroke(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchesTabStroke(event: event, stroke: shortcut.firstStroke)
    }

    /// Whether `event` matches `stroke` as a directional shortcut: arrow-key code
    /// match when the stroke is the arrow glyph, otherwise the normal-key predicate
    /// (so users can rebind directional navigation to letter keys).
    func matchesDirectionalStroke(
        event: NSEvent,
        stroke: ShortcutStroke,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        matchesDirectionalStroke(
            event: event,
            strokeKey: stroke.key,
            strokeModifierFlags: stroke.modifierFlags,
            strokeKeyCode: stroke.keyCode,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode,
            optionTextBypass: shortcutRoutingShouldBypassForPrintableOptionText(event: event),
            layoutCharacterProvider: layoutCharacter(forKeyCode:modifierFlags:)
        )
    }

    /// Whether `event` matches a directional `shortcut`'s single stroke, skipping
    /// chorded shortcuts.
    func matchesDirectionalStroke(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchesDirectionalStroke(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }
}

extension ShortcutStroke {
    /// This stroke as its persisted ``CmuxSettings/ShortcutStroke`` value.
    ///
    /// The app-target stroke is field-identical to the package stroke; this
    /// adapter is the single point where the two shapes meet so the config
    /// grammar can live entirely in `CmuxShortcuts`.
    var cmuxSettingsShortcutStroke: CmuxSettings.ShortcutStroke {
        CmuxSettings.ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }

    /// Reconstructs an app-target stroke from a persisted
    /// ``CmuxSettings/ShortcutStroke`` value.
    init(cmuxSettings stroke: CmuxSettings.ShortcutStroke) {
        self.init(
            key: stroke.key,
            command: stroke.command,
            shift: stroke.shift,
            option: stroke.option,
            control: stroke.control,
            keyCode: stroke.keyCode
        )
    }

    /// Parses one config token into an app-target stroke by delegating to the
    /// `cmd+shift+x` grammar in ``CmuxSettings/ShortcutStroke/parseConfig(_:)``.
    static func parseConfig(_ rawValue: String) -> ShortcutStroke? {
        CmuxSettings.ShortcutStroke.parseConfig(rawValue).map(ShortcutStroke.init(cmuxSettings:))
    }

    /// Formats this stroke as a config token via the grammar in
    /// ``CmuxSettings/ShortcutStroke/configString(preserveDigit:)``.
    func configString(preserveDigit: Bool = true) -> String {
        cmuxSettingsShortcutStroke.configString(preserveDigit: preserveDigit)
    }
}

extension StoredShortcut {
    /// Reconstructs an app-target binding from a persisted
    /// ``CmuxSettings/StoredShortcut`` value.
    init(cmuxSettings shortcut: CmuxSettings.StoredShortcut) {
        if shortcut.isUnbound {
            self = .unbound
            return
        }
        self.init(
            first: ShortcutStroke(cmuxSettings: shortcut.first),
            second: shortcut.second.map(ShortcutStroke.init(cmuxSettings:))
        )
    }

    /// Parses a single config token (string form) into an app-target binding by
    /// delegating to ``CmuxSettings/StoredShortcut/parseConfig(_:allowBareFirstStroke:)``.
    static func parseConfig(_ rawValue: String, allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        CmuxSettings.StoredShortcut.parseConfig(rawValue, allowBareFirstStroke: allowBareFirstStroke)
            .map(StoredShortcut.init(cmuxSettings:))
    }

    /// Parses a one-or-two-stroke chord array into an app-target binding by
    /// delegating to ``CmuxSettings/StoredShortcut/parseConfig(strokes:allowBareFirstStroke:)``.
    static func parseConfig(strokes: [String], allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        CmuxSettings.StoredShortcut.parseConfig(strokes: strokes, allowBareFirstStroke: allowBareFirstStroke)
            .map(StoredShortcut.init(cmuxSettings:))
    }

    /// The canonical config token(s) for this binding via
    /// ``CmuxSettings/StoredShortcut/configIdentifier``.
    var configIdentifier: String {
        cmuxSettingsStoredShortcut.configIdentifier
    }
}

enum KeyboardShortcutRecorderActivity {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutRecorderActivityDidChange")
    static let stopAllNotification = Notification.Name("cmux.keyboardShortcutRecorderActivityStopAll")
    private static var activeRecorderCount = 0

    static var isAnyRecorderActive: Bool {
        activeRecorderCount > 0
    }

    static func beginRecording(center: NotificationCenter = .default) {
        let wasActive = isAnyRecorderActive
        activeRecorderCount += 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

    static func endRecording(center: NotificationCenter = .default) {
        guard activeRecorderCount > 0 else { return }
        let wasActive = isAnyRecorderActive
        activeRecorderCount -= 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

    static func stopAllRecording(center: NotificationCenter = .default) {
        let wasActive = isAnyRecorderActive
        center.post(name: stopAllNotification, object: nil)
        guard activeRecorderCount > 0 else { return }
        activeRecorderCount = 0
        if wasActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

#if DEBUG
    static func resetForTesting(center: NotificationCenter = .default) {
        // Keep test isolation from broadcasting stop-all UI notifications into unrelated live windows.
        let wasActive = isAnyRecorderActive
        activeRecorderCount = 0
        if wasActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }
#endif
}

struct ShortcutRecorderRejectedAttempt: Equatable {
    let reason: KeyboardShortcutSettings.ShortcutRecordingRejection
    let proposedShortcut: StoredShortcut?
}

/// The configured-chord-aware shortcut matchers that resolve a bound
/// ``KeyboardShortcutSettings/Action`` (or an explicit ``StoredShortcut``) against
/// a live key `NSEvent`, branching on the active chord prefix.
///
/// ## Why these live on ``CmuxShortcuts/ShortcutCoordinator``
///
/// These were `private` matchers on the app-target ``AppDelegate``, the keyboard-
/// shortcut god object. Deciding whether an event satisfies a *configured* binding
/// is shortcut-routing orchestration, not app-shell lifecycle, so it belongs on
/// the coordinator that already owns the decode (``CmuxShortcuts/ShortcutCoordinator``
/// `+Matching`) and the single-stroke `matchesStroke`/`numberedShortcutDigit`/
/// `matchesDirectionalStroke` primitives these methods delegate to. Moving them off
/// ``AppDelegate`` continues the de-singletonization of that god object: the
/// per-keystroke dispatch (`handleCustomShortcut` et al.) now calls the coordinator,
/// not a private self-method, passing the held chord coordinator and the app-side
/// `when`-clause / window-number lookups as collaborators.
///
/// ## Why this extension is app-side, not in the package
///
/// The matchers intrinsically read the app-target shortcut catalog
/// (``KeyboardShortcutSettings/shortcut(for:)``), the app-target value types
/// (``StoredShortcut``, ``ShortcutStroke``), and the app-target `when`-clause focus
/// gate, none of which can cross into ``CmuxShortcuts`` (a lower package cannot
/// depend on an app-target type). So they land as instance methods on the
/// coordinator through an app-target `extension`, alongside the single-stroke
/// `matchesStroke(event:shortcut:)` adapters earlier in this file: the package owns
/// the pure matching ladder, this seam decomposes the app catalog into it.
///
/// ## Collaborators
///
/// - `chord`: the held ``CmuxWindowing/ShortcutChordCoordinator`` `<ShortcutStroke>`
///   whose `activePrefixForCurrentEvent` selects first-stroke vs second-stroke
///   matching and whose `armIfNeeded(...)` records a chord prefix.
/// - `whenClauseAllows`: the app-side `when`-clause focus gate
///   (`AppDelegate.shortcutWhenClauseAllows(action:event:)`), injected because it
///   reads the live focus snapshot.
/// - `chordWindowNumber`: the window-number lookup used to scope a chord to the
///   window that armed it, injected because it reaches `mainWindowForShortcutEvent`
///   / `event.window` window-domain state that stays app-side.
extension ShortcutCoordinator {
    /// Whether `event` matches `shortcut`, honoring the active chord prefix: when a
    /// prefix is live, only a chorded shortcut whose first stroke equals that prefix
    /// can match (on its second stroke); otherwise only a non-chorded shortcut can
    /// match (on its single stroke). Faithful relocation of the former
    /// `AppDelegate.matchConfiguredShortcut(event:shortcut:)`.
    func matchConfiguredShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        chord: ShortcutChordCoordinator<ShortcutStroke>
    ) -> Bool {
        guard !shortcut.isUnbound else { return false }
        if let prefix = chord.activePrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchesStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchesStroke(event: event, stroke: shortcut.firstStroke)
    }

    /// Whether `event` matches `action`'s configured binding, after the action's
    /// effective `when` clause is satisfied by the event's focus state. Faithful
    /// relocation of the former `AppDelegate.matchConfiguredShortcut(event:action:)`.
    func matchConfiguredShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        chord: ShortcutChordCoordinator<ShortcutStroke>,
        whenClauseAllows: (KeyboardShortcutSettings.Action, NSEvent) -> Bool
    ) -> Bool {
        if !whenClauseAllows(action, event) { return false }
        return matchConfiguredShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: action),
            chord: chord
        )
    }

    /// The numbered digit (1–9) `action`'s configured binding matches for `event`,
    /// honoring the active chord prefix, or `nil`. Faithful relocation of the former
    /// `AppDelegate.numberedConfiguredShortcutDigit(event:action:)`.
    func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        chord: ShortcutChordCoordinator<ShortcutStroke>
    ) -> Int? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return nil }
        if let prefix = chord.activePrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return nil
            }
            return numberedShortcutDigit(event: event, stroke: secondStroke)
        }
        guard !shortcut.isUnbound, !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    /// Whether `event` matches `action`'s configured directional binding, honoring
    /// the action's `when` clause and the active chord prefix. Faithful relocation of
    /// the former `AppDelegate.matchConfiguredDirectionalShortcut(event:action:arrowGlyph:arrowKeyCode:)`.
    func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16,
        chord: ShortcutChordCoordinator<ShortcutStroke>,
        whenClauseAllows: (KeyboardShortcutSettings.Action, NSEvent) -> Bool
    ) -> Bool {
        guard whenClauseAllows(action, event) else {
            return false
        }
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return false }
        if let prefix = chord.activePrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchesDirectionalStroke(
                event: event,
                stroke: secondStroke,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            )
        }
        guard !shortcut.hasChord else { return false }
        return matchesDirectionalStroke(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    /// Arms a chord prefix if any of `actions`' bindings (plus any explicit
    /// `shortcuts`) is a chorded shortcut whose first stroke matches `event`,
    /// scoping the chord to the event's window via `chordWindowNumber`. Faithful
    /// relocation of the former `AppDelegate.armConfiguredShortcutChordIfNeeded(event:actions:shortcuts:)`.
    func armConfiguredShortcutChordIfNeeded(
        event: NSEvent,
        actions: [KeyboardShortcutSettings.Action],
        shortcuts: [StoredShortcut] = [],
        chord: ShortcutChordCoordinator<ShortcutStroke>,
        chordWindowNumber: (NSEvent) -> Int?
    ) -> Bool {
        let configuredShortcuts = actions.map {
            KeyboardShortcutSettings.shortcut(for: $0)
        } + shortcuts
        return chord.armIfNeeded(
            candidates: configuredShortcuts,
            windowNumber: chordWindowNumber(event),
            isChord: { $0.hasChord },
            firstStroke: { $0.firstStroke },
            firstStrokeMatches: { matchesStroke(event: event, stroke: $0) }
        )
    }
}
