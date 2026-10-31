import CmuxNextActions
import Foundation

/// Localized strings for the palette. Keys live in Localizable.xcstrings (en, ja).
nonisolated enum PaletteStrings {
    static var sectionPinned: String { String(localized: "palette.section.pinned", defaultValue: "Pinned", bundle: .module) }
    static var sectionSuggested: String { String(localized: "palette.section.suggested", defaultValue: "Suggested", bundle: .module) }
    static var sectionRecent: String { String(localized: "palette.section.recent", defaultValue: "Recent", bundle: .module) }
    static var sectionWorkspaces: String { String(localized: "palette.section.workspaces", defaultValue: "Workspaces", bundle: .module) }
    static var sectionTabs: String { String(localized: "palette.section.tabs", defaultValue: "Tabs", bundle: .module) }
    static var sectionOpenIn: String { String(localized: "palette.section.openIn", defaultValue: "Open In", bundle: .module) }
    static var sectionSettings: String { String(localized: "palette.section.settings", defaultValue: "Change Settings", bundle: .module) }
    static var sectionRecentDirectories: String { String(localized: "palette.section.recentDirectories", defaultValue: "Recent Directories", bundle: .module) }
    static var commandsTitle: String { String(localized: "palette.page.commands", defaultValue: "Commands", bundle: .module) }
    static var searchPlaceholder: String { String(localized: "palette.placeholder.commands", defaultValue: "Search for commands…", bundle: .module) }
    static var shortcutsTitle: String { String(localized: "palette.page.shortcuts", defaultValue: "Keyboard Shortcuts", bundle: .module) }
    static var shortcutsPlaceholder: String { String(localized: "palette.placeholder.shortcuts", defaultValue: "Search shortcuts by name or keys…", bundle: .module) }
    static var workspacesTitle: String { String(localized: "palette.page.workspaces", defaultValue: "Go to Workspace", bundle: .module) }
    static func workspaceNotFound(_ id: String) -> String {
        String(localized: "palette.goToWorkspace.notFound", defaultValue: "No workspace \(id).", bundle: .module)
    }
    static var workspacesPlaceholder: String { String(localized: "palette.placeholder.workspaces", defaultValue: "Search workspaces…", bundle: .module) }
    static var tabsTitle: String { String(localized: "palette.page.tabs", defaultValue: "Go to Tab", bundle: .module) }
    static var tabsPlaceholder: String { String(localized: "palette.placeholder.tabs", defaultValue: "Search tabs…", bundle: .module) }
    static var openInTitle: String { String(localized: "palette.page.openIn", defaultValue: "Open Current Directory", bundle: .module) }
    static var openInPlaceholder: String { String(localized: "palette.placeholder.openIn", defaultValue: "Search apps…", bundle: .module) }
    static var settingsTitle: String { String(localized: "palette.page.settings", defaultValue: "Change Settings", bundle: .module) }
    static var settingsPlaceholder: String { String(localized: "palette.placeholder.settings", defaultValue: "Search settings…", bundle: .module) }
    static var searchActionsPlaceholder: String { String(localized: "palette.placeholder.actions", defaultValue: "Search actions…", bundle: .module) }
    static var noResults: String { String(localized: "palette.noResults", defaultValue: "No Results", bundle: .module) }
    static var noResultsHint: String { String(localized: "palette.noResults.hint", defaultValue: "Try a different search, or press Esc to go back.", bundle: .module) }
    static var actions: String { String(localized: "palette.footer.actions", defaultValue: "Actions", bundle: .module) }
    static var hideFromPalette: String { String(localized: "palette.action.hideFromPalette", defaultValue: "Hide from Palette", bundle: .module) }
    static var showInPalette: String { String(localized: "palette.action.showInPalette", defaultValue: "Show in Palette", bundle: .module) }
    static var resetRanking: String { String(localized: "palette.action.resetRanking", defaultValue: "Reset Ranking", bundle: .module) }
    static var back: String { String(localized: "palette.back", defaultValue: "Back", bundle: .module) }
    static var unbound: String { String(localized: "palette.unbound", defaultValue: "Not bound", bundle: .module) }
    static var copyActionID: String { String(localized: "palette.command.copyActionID", defaultValue: "Copy Action ID", bundle: .module) }
    static var copyShortcut: String { String(localized: "palette.command.copyShortcut", defaultValue: "Copy Shortcut", bundle: .module) }
    static var copyID: String { String(localized: "palette.command.copyID", defaultValue: "Copy ID", bundle: .module) }
    static var copyPath: String { String(localized: "palette.command.copyPath", defaultValue: "Copy Path", bundle: .module) }
    static var runCommand: String { String(localized: "palette.command.run", defaultValue: "Run Command", bundle: .module) }
    static var open: String { String(localized: "palette.command.open", defaultValue: "Open", bundle: .module) }
    /// Open Recovered Draft…'s page: its title and its search field.
    static var recoveredDraftsTitle: String {
        String(localized: "palette.recoveredDrafts.title", defaultValue: "Recovered Drafts", bundle: .module)
    }
    static var recoveredDraftsPlaceholder: String {
        String(localized: "palette.recoveredDrafts.placeholder", defaultValue: "Find a recovered draft", bundle: .module)
    }
    static var submit: String { String(localized: "palette.command.submit", defaultValue: "Submit", bundle: .module) }
    static var current: String { String(localized: "palette.accessory.current", defaultValue: "Current", bundle: .module) }
    static var on: String { String(localized: "palette.accessory.on", defaultValue: "On", bundle: .module) }
    static var off: String { String(localized: "palette.accessory.off", defaultValue: "Off", bundle: .module) }
    static var changeFont: String { String(localized: "palette.setting.changeFont", defaultValue: "Change Font…", bundle: .module) }
    static var customValue: String { String(localized: "palette.setting.customValue", defaultValue: "Custom Value…", bundle: .module) }
    static var turnOn: String { String(localized: "palette.command.turnOn", defaultValue: "Turn On", bundle: .module) }
    static var turnOff: String { String(localized: "palette.command.turnOff", defaultValue: "Turn Off", bundle: .module) }
    static var workspaceKeyword: String { String(localized: "palette.keyword.workspace", defaultValue: "workspace", bundle: .module) }
    static var tabKeyword: String { String(localized: "palette.keyword.tab", defaultValue: "tab", bundle: .module) }
    static var groupKeyword: String { String(localized: "palette.keyword.group", defaultValue: "group", bundle: .module) }
    static var paneKeyword: String { String(localized: "palette.keyword.pane", defaultValue: "pane", bundle: .module) }
    static var sectionGroups: String { String(localized: "palette.section.groups", defaultValue: "Groups", bundle: .module) }
    static var sectionPanes: String { String(localized: "palette.section.panes", defaultValue: "Panes", bundle: .module) }
    /// The Search scope's title (the sidebar's Search button) and its field's placeholder.
    static var searchEverythingTitle: String { String(localized: "palette.scope.search", defaultValue: "Search", bundle: .module) }
    /// The Chats & agents scope: Search narrowed to agent chats and sessions.
    static var chatsAndAgentsTitle: String { String(localized: "palette.scope.chats", defaultValue: "Chats & agents", bundle: .module) }
    static var chatsAndAgentsPlaceholder: String {
        String(localized: "palette.placeholder.chatsAndAgents", defaultValue: "Search chats and agents…", bundle: .module)
    }
    static var searchEverythingPlaceholder: String {
        String(localized: "palette.placeholder.searchEverything", defaultValue: "Search workspaces, tabs, history, chats, settings and commands…", bundle: .module)
    }
    static var goToAnythingPlaceholder: String {
        String(localized: "palette.placeholder.goToAnything", defaultValue: "Search workspaces, groups, panes and tabs…", bundle: .module)
    }
    static var copySessionID: String { String(localized: "palette.command.copySessionID", defaultValue: "Copy Session ID", bundle: .module) }
    static var goToGroup: String { String(localized: "palette.command.goToGroup", defaultValue: "Go to Group", bundle: .module) }
    static var focusPane: String { String(localized: "palette.command.focusPane", defaultValue: "Focus Pane", bundle: .module) }
    static func groupWorkspaceCount(_ count: Int) -> String {
        String(localized: "palette.group.workspaceCount", defaultValue: "Workspaces: \(count)", bundle: .module)
    }
    // The kind of a Go to Workspace row, drawn at its right edge.
    static var kindGroup: String { String(localized: "palette.kind.group", defaultValue: "Group", bundle: .module) }
    static var kindPane: String { String(localized: "palette.kind.pane", defaultValue: "Pane", bundle: .module) }
    static var kindTab: String { String(localized: "palette.kind.tab", defaultValue: "Tab", bundle: .module) }
    static var kindTerminal: String { String(localized: "palette.kind.terminal", defaultValue: "Terminal", bundle: .module) }
    static var kindBrowser: String { String(localized: "palette.kind.browser", defaultValue: "Browser", bundle: .module) }
    static var kindRemoteTerminal: String { String(localized: "palette.kind.remoteTerminal", defaultValue: "Remote Terminal", bundle: .module) }
    static var kindAgentChat: String { String(localized: "palette.kind.agentChat", defaultValue: "Agent Chat", bundle: .module) }
    static var kindMarkdown: String { String(localized: "palette.kind.markdown", defaultValue: "Markdown", bundle: .module) }
    static var kindFile: String { String(localized: "palette.kind.file", defaultValue: "File", bundle: .module) }
    static var kindPage: String { String(localized: "palette.kind.page", defaultValue: "Page", bundle: .module) }
    static var switchToWorkspace: String { String(localized: "palette.command.switchToWorkspace", defaultValue: "Switch to Workspace", bundle: .module) }
    static var renameWorkspace: String { String(localized: "palette.command.renameWorkspace", defaultValue: "Rename Workspace…", bundle: .module) }
    static var closeWorkspace: String { String(localized: "palette.command.closeWorkspace", defaultValue: "Close Workspace", bundle: .module) }
    static var workspaceNamePlaceholder: String { String(localized: "palette.placeholder.workspaceName", defaultValue: "Workspace name", bundle: .module) }
    static var switchToTab: String { String(localized: "palette.command.switchToTab", defaultValue: "Switch to Tab", bundle: .module) }
    static var renameTab: String { String(localized: "palette.command.renameTab", defaultValue: "Rename Tab…", bundle: .module) }
    static var closeTab: String { String(localized: "palette.command.closeTab", defaultValue: "Close Tab", bundle: .module) }
    static var tabNamePlaceholder: String { String(localized: "palette.placeholder.tabName", defaultValue: "Tab name", bundle: .module) }
    static var choose: String { String(localized: "palette.command.choose", defaultValue: "Choose", bundle: .module) }
    static var openInNewWorkspace: String { String(localized: "palette.command.openInNewWorkspace", defaultValue: "Open in New Workspace", bundle: .module) }

    static func unreadCount(_ count: Int) -> String {
        String(localized: "palette.accessory.unread", defaultValue: "\(count) unread", bundle: .module)
    }
    static func renameTo(_ text: String) -> String {
        String(localized: "palette.renameTo", defaultValue: "Rename to “\(text)”", bundle: .module)
    }
    static func openIn(_ app: String) -> String {
        String(localized: "palette.openIn", defaultValue: "Open in \(app)", bundle: .module)
    }
    static var added: String { String(localized: "palette.accessory.added", defaultValue: "Added", bundle: .module) }
    static func continueWith(_ names: String) -> String {
        String(localized: "palette.members.continue", defaultValue: "Continue with \(names)", bundle: .module)
    }
    static func addTyped(_ text: String) -> String {
        String(localized: "palette.members.add", defaultValue: "Add “\(text)”", bundle: .module)
    }
    static func removeToken(_ name: String) -> String {
        String(localized: "palette.members.remove", defaultValue: "Remove \(name)", bundle: .module)
    }
    static func chooseArgument(_ name: String) -> String {
        String(localized: "palette.chooseArgument", defaultValue: "Choose \(name)…", bundle: .module)
    }
    static func submitTextFormat(title: String, text: String) -> String {
        String(localized: "palette.submitText", defaultValue: "\(title) “\(text)”", bundle: .module)
    }

    /// Row title for inline entry of a catalog action: the action title
    /// without its trailing ellipsis, then the quoted text.
    static func submitText(title: String, text: String) -> String {
        let base = title.hasSuffix("…") ? String(title.dropLast()) : title
        return submitTextFormat(title: base, text: text)
    }
}

// Shortcut recorder (Cmd-K on an action): text lives with the shared
// recorder in CmuxNextActions.
extension PaletteStrings {
    static var editShortcut: String { ShortcutRecorderStrings.editShortcut }
    static var recorderTitle: String { ShortcutRecorderStrings.recorderTitle }
    static var noShortcut: String { ShortcutRecorderStrings.noShortcut }
    static var optionSave: String { ShortcutRecorderStrings.optionSave }
    static var optionReplace: String { ShortcutRecorderStrings.optionReplace }
    static var optionKeepBoth: String { ShortcutRecorderStrings.optionKeepBoth }
    static var optionCancel: String { ShortcutRecorderStrings.optionCancel }
    static var optionRemove: String { ShortcutRecorderStrings.optionRemove }
    static var optionRestoreDefault: String { ShortcutRecorderStrings.optionRestoreDefault }
    // Cmd-P and Cmd-Shift-P rows for a typed path or web address (GoToPaletteRows).
    static var sectionGoTo: String { String(localized: "palette.section.goTo", defaultValue: "Go To", bundle: .module) }
    static var kindFolder: String { String(localized: "palette.kind.folder", defaultValue: "Folder", bundle: .module) }
    static func goToOpen(_ place: String) -> String { String(localized: "palette.goTo.open", defaultValue: "Open \(place)", bundle: .module) }
    static var goToFolderHint: String { String(localized: "palette.goTo.folderHint", defaultValue: "New terminal tab in this folder", bundle: .module) }
    static var goToAskCommand: String { String(localized: "palette.goTo.askCommand", defaultValue: "Ask Agent", bundle: .module) }
    static func goToAsk(_ place: String) -> String { String(localized: "palette.goTo.ask", defaultValue: "Ask Agent about \(place)", bundle: .module) }
    static func goToAskWithPrompt(_ place: String, _ prompt: String) -> String {
        String(localized: "palette.goTo.askWithPrompt", defaultValue: "Ask Agent about \(place): \(prompt)", bundle: .module)
    }
    static var goToAskHint: String { String(localized: "palette.goTo.askHint", defaultValue: "New agent chat; type your prompt", bundle: .module) }
    static var goToAskSendsHint: String { String(localized: "palette.goTo.askSendsHint", defaultValue: "New agent chat; sends this prompt", bundle: .module) }
    static var goToCopyURL: String { String(localized: "palette.goTo.copyURL", defaultValue: "Copy URL", bundle: .module) }
}
