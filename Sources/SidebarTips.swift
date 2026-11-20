import Foundation
import CmuxSidebar

/// One short "how to use cmux" tip shown by the sidebar footer's Tips button.
struct SidebarTip: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    /// Shortcut shown beside the title. It is read live from the user's
    /// bindings, so a rebound or unbound action never shows a wrong key.
    let shortcutAction: KeyboardShortcutSettings.Action?
    /// The tip describes the hold-Command shortcut hints, so it only applies
    /// while that setting is on.
    let requiresModifierHoldHints: Bool

    init(
        id: String,
        title: String,
        message: String,
        shortcutAction: KeyboardShortcutSettings.Action? = nil,
        requiresModifierHoldHints: Bool = false
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.shortcutAction = shortcutAction
        self.requiresModifierHoldHints = requiresModifierHoldHints
    }
}

/// The tips, in the order they are offered. Every tip names a real feature;
/// shortcuts come from `KeyboardShortcutSettings`, never from the copy.
enum SidebarTipsCatalog {
    static var all: [SidebarTip] {
        [
            SidebarTip(
                id: "commandPalette",
                title: String(localized: "sidebar.tips.commandPalette.title", defaultValue: "Command Palette"),
                message: String(
                    localized: "sidebar.tips.commandPalette.message",
                    defaultValue: "Run any cmux command by typing its name."
                ),
                shortcutAction: .commandPalette
            ),
            SidebarTip(
                id: "goToWorkspace",
                title: String(localized: "sidebar.tips.goToWorkspace.title", defaultValue: "Go to a workspace"),
                message: String(
                    localized: "sidebar.tips.goToWorkspace.message",
                    defaultValue: "Switch to any workspace by typing part of its name."
                ),
                shortcutAction: .goToWorkspace
            ),
            SidebarTip(
                id: "splitPanes",
                title: String(localized: "sidebar.tips.splitPanes.title", defaultValue: "Split panes"),
                message: String(
                    localized: "sidebar.tips.splitPanes.message",
                    defaultValue: "Put two terminals side by side in one workspace."
                ),
                shortcutAction: .splitRight
            ),
            SidebarTip(
                id: "zoomPane",
                title: String(localized: "sidebar.tips.zoomPane.title", defaultValue: "Zoom a pane"),
                message: String(
                    localized: "sidebar.tips.zoomPane.message",
                    defaultValue: "Let one pane fill the workspace for a while, then switch back to the split the same way."
                ),
                shortcutAction: .toggleSplitZoom
            ),
            SidebarTip(
                id: "browserSplit",
                title: String(localized: "sidebar.tips.browserSplit.title", defaultValue: "Browser next to your terminal"),
                message: String(
                    localized: "sidebar.tips.browserSplit.message",
                    defaultValue: "Open a browser pane beside your terminal, in the same workspace."
                ),
                shortcutAction: .splitBrowserRight
            ),
            SidebarTip(
                id: "jumpToUnread",
                title: String(localized: "sidebar.tips.jumpToUnread.title", defaultValue: "Jump to what needs you"),
                message: String(
                    localized: "sidebar.tips.jumpToUnread.message",
                    defaultValue: "Go straight to the latest unread notification, in whichever workspace it came from."
                ),
                shortcutAction: .jumpToUnread
            ),
            SidebarTip(
                id: "notifyCommand",
                title: String(localized: "sidebar.tips.notifyCommand.title", defaultValue: "Get notified when a command ends"),
                message: String(
                    localized: "sidebar.tips.notifyCommand.message",
                    defaultValue: "Put cmux notify after a long command, like make; cmux notify, and its pane lights up when it is done."
                )
            ),
            SidebarTip(
                id: "holdCommand",
                title: String(localized: "sidebar.tips.holdCommand.title", defaultValue: "Hold ⌘ for shortcuts"),
                message: String(
                    localized: "sidebar.tips.holdCommand.message",
                    defaultValue: "Holding ⌘ shows the shortcut for each workspace and a button that lists every shortcut."
                ),
                requiresModifierHoldHints: true
            ),
            SidebarTip(
                id: "newWorkspace",
                title: String(localized: "sidebar.tips.newWorkspace.title", defaultValue: "A workspace for each task"),
                message: String(
                    localized: "sidebar.tips.newWorkspace.message",
                    defaultValue: "Start a separate workspace to keep a new task’s terminals and browser tabs together."
                ),
                shortcutAction: .newTab
            ),
            SidebarTip(
                id: "renameWorkspace",
                title: String(localized: "sidebar.tips.renameWorkspace.title", defaultValue: "Name your workspace"),
                message: String(
                    localized: "sidebar.tips.renameWorkspace.message",
                    defaultValue: "Give a workspace a short name so it is easy to find in the sidebar."
                ),
                shortcutAction: .renameWorkspace
            ),
            SidebarTip(
                id: "workspaceDescription",
                title: String(localized: "sidebar.tips.workspaceDescription.title", defaultValue: "Leave yourself a note"),
                message: String(
                    localized: "sidebar.tips.workspaceDescription.message",
                    defaultValue: "Add a workspace description to remember what you were working on."
                ),
                shortcutAction: .editWorkspaceDescription
            ),
            SidebarTip(
                id: "workspaceGroups",
                title: String(localized: "sidebar.tips.workspaceGroups.title", defaultValue: "Group related work"),
                message: String(
                    localized: "sidebar.tips.workspaceGroups.message",
                    defaultValue: "Select related workspaces, then put them in a group you can collapse in the sidebar."
                ),
                shortcutAction: .groupSelectedWorkspaces
            ),
            SidebarTip(
                id: "reopenWorkspace",
                title: String(localized: "sidebar.tips.reopenWorkspace.title", defaultValue: "Restore a workspace"),
                message: String(
                    localized: "sidebar.tips.reopenWorkspace.message",
                    defaultValue: "Bring back a recently closed workspace from its saved layout."
                ),
                shortcutAction: .reopenClosedWorkspace
            ),
            SidebarTip(
                id: "reorderWorkspace",
                title: String(localized: "sidebar.tips.reorderWorkspace.title", defaultValue: "Reorder your work"),
                message: String(
                    localized: "sidebar.tips.reorderWorkspace.message",
                    defaultValue: "Move the current workspace up in the sidebar to keep active tasks close at hand."
                ),
                shortcutAction: .moveWorkspaceUp
            ),
            SidebarTip(
                id: "newTerminalTab",
                title: String(localized: "sidebar.tips.newTerminalTab.title", defaultValue: "Another terminal tab"),
                message: String(
                    localized: "sidebar.tips.newTerminalTab.message",
                    defaultValue: "Open another terminal tab in the same pane without changing your split layout."
                ),
                shortcutAction: .newSurface
            ),
            SidebarTip(
                id: "renameTab",
                title: String(localized: "sidebar.tips.renameTab.title", defaultValue: "Label your tabs"),
                message: String(
                    localized: "sidebar.tips.renameTab.message",
                    defaultValue: "Give a tab a name that describes the command or task running there."
                ),
                shortcutAction: .renameTab
            ),
            SidebarTip(
                id: "nextWorkspace",
                title: String(localized: "sidebar.tips.nextWorkspace.title", defaultValue: "Switch workspaces quickly"),
                message: String(
                    localized: "sidebar.tips.nextWorkspace.message",
                    defaultValue: "Move to the next workspace without reaching for the sidebar."
                ),
                shortcutAction: .nextSidebarTab
            ),
            SidebarTip(
                id: "nextPane",
                title: String(localized: "sidebar.tips.nextPane.title", defaultValue: "Move between panes"),
                message: String(
                    localized: "sidebar.tips.nextPane.message",
                    defaultValue: "Focus the next pane to keep working without using the mouse."
                ),
                shortcutAction: .focusNextPane
            ),
            SidebarTip(
                id: "splitBelow",
                title: String(localized: "sidebar.tips.splitBelow.title", defaultValue: "Stack your terminals"),
                message: String(
                    localized: "sidebar.tips.splitBelow.message",
                    defaultValue: "Split downward to place a second terminal below the one you are using."
                ),
                shortcutAction: .splitDown
            ),
            SidebarTip(
                id: "equalizePanes",
                title: String(localized: "sidebar.tips.equalizePanes.title", defaultValue: "Balance your splits"),
                message: String(
                    localized: "sidebar.tips.equalizePanes.message",
                    defaultValue: "Give split panes equal space again after resizing them."
                ),
                shortcutAction: .equalizeSplits
            ),
            SidebarTip(
                id: "terminalTextSize",
                title: String(localized: "sidebar.tips.terminalTextSize.title", defaultValue: "Make text easier to read"),
                message: String(
                    localized: "sidebar.tips.terminalTextSize.message",
                    defaultValue: "Increase terminal text size across the current workspace."
                ),
                shortcutAction: .increaseWorkspaceTerminalFontSize
            ),
            SidebarTip(
                id: "copyMode",
                title: String(localized: "sidebar.tips.copyMode.title", defaultValue: "Copy with the keyboard"),
                message: String(
                    localized: "sidebar.tips.copyMode.message",
                    defaultValue: "Use terminal copy mode to navigate and select output without the mouse."
                ),
                shortcutAction: .toggleTerminalCopyMode
            ),
            SidebarTip(
                id: "findText",
                title: String(localized: "sidebar.tips.findText.title", defaultValue: "Find text in a pane"),
                message: String(
                    localized: "sidebar.tips.findText.message",
                    defaultValue: "Search the focused terminal’s output or the current browser page."
                ),
                shortcutAction: .find
            ),
            SidebarTip(
                id: "findSelection",
                title: String(localized: "sidebar.tips.findSelection.title", defaultValue: "Search selected text"),
                message: String(
                    localized: "sidebar.tips.findSelection.message",
                    defaultValue: "Use the selected text as your next search query."
                ),
                shortcutAction: .useSelectionForFind
            ),
            SidebarTip(
                id: "sidebarSpace",
                title: String(localized: "sidebar.tips.sidebarSpace.title", defaultValue: "More room for your work"),
                message: String(
                    localized: "sidebar.tips.sidebarSpace.message",
                    defaultValue: "Hide the workspace sidebar when you want more space for your panes."
                ),
                shortcutAction: .toggleSidebar
            ),
            SidebarTip(
                id: "browseFiles",
                title: String(localized: "sidebar.tips.browseFiles.title", defaultValue: "Files beside your terminal"),
                message: String(
                    localized: "sidebar.tips.browseFiles.message",
                    defaultValue: "Browse your workspace’s files in the right sidebar."
                ),
                shortcutAction: .switchRightSidebarToFiles
            ),
            SidebarTip(
                id: "searchFiles",
                title: String(localized: "sidebar.tips.searchFiles.title", defaultValue: "Search across files"),
                message: String(
                    localized: "sidebar.tips.searchFiles.message",
                    defaultValue: "Find text across files in a directory from inside cmux."
                ),
                shortcutAction: .findInDirectory
            ),
            SidebarTip(
                id: "reviewChanges",
                title: String(localized: "sidebar.tips.reviewChanges.title", defaultValue: "Review your changes"),
                message: String(
                    localized: "sidebar.tips.reviewChanges.message",
                    defaultValue: "Inspect your Git changes in a diff view beside your terminal."
                ),
                shortcutAction: .openDiffViewer
            ),
            SidebarTip(
                id: "browserAddress",
                title: String(localized: "sidebar.tips.browserAddress.title", defaultValue: "Jump to the address bar"),
                message: String(
                    localized: "sidebar.tips.browserAddress.message",
                    defaultValue: "Focus the browser address bar to enter a URL or start a search."
                ),
                shortcutAction: .focusBrowserAddressBar
            ),
            SidebarTip(
                id: "reopenLastClosed",
                title: String(localized: "sidebar.tips.reopenLastClosed.title", defaultValue: "Undo a close"),
                message: String(
                    localized: "sidebar.tips.reopenLastClosed.message",
                    defaultValue: "Bring back the last tab or workspace you closed."
                ),
                shortcutAction: .reopenClosedBrowserPanel
            ),
            SidebarTip(
                id: "browserZoom",
                title: String(localized: "sidebar.tips.browserZoom.title", defaultValue: "Zoom a browser page"),
                message: String(
                    localized: "sidebar.tips.browserZoom.message",
                    defaultValue: "Enlarge the current browser page without changing your terminal text size."
                ),
                shortcutAction: .browserZoomIn
            ),
            SidebarTip(
                id: "notifications",
                title: String(localized: "sidebar.tips.notifications.title", defaultValue: "Catch up on notifications"),
                message: String(
                    localized: "sidebar.tips.notifications.message",
                    defaultValue: "Open the notification panel to see which workspaces need your attention."
                ),
                shortcutAction: .showNotifications
            ),
        ]
    }

    static func visibleTips(showsModifierHoldHints: Bool) -> [SidebarTip] {
        all.filter { !$0.requiresModifierHoldHints || showsModifierHoldHints }
    }
}
