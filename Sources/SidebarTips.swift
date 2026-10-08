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
        ]
    }

    static func visibleTips(showsModifierHoldHints: Bool) -> [SidebarTip] {
        all.filter { !$0.requiresModifierHoldHints || showsModifierHoldHints }
    }
}
