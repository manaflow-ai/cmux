import CmuxNextActions
import Foundation

/// Localized strings for the palette. Keys live in Localizable.xcstrings (en, ja).
nonisolated enum PaletteStrings {
    static var target: String { String(localized: "palette.target", defaultValue: "Choose a target", bundle: .l10n) }
    static var chooseTarget: String { String(localized: "palette.target.search", defaultValue: "Search…", bundle: .l10n) }
    static var sectionPinned: String { String(localized: "palette.section.pinned", defaultValue: "Pinned", bundle: .l10n) }
    static var sectionSuggested: String { String(localized: "palette.section.suggested", defaultValue: "Suggested", bundle: .l10n) }
    static var sectionRecent: String { String(localized: "palette.section.recent", defaultValue: "Recent", bundle: .l10n) }
    static var sectionWorkspaces: String { String(localized: "palette.section.workspaces", defaultValue: "Workspaces", bundle: .l10n) }
    static var sectionTabs: String { String(localized: "palette.section.tabs", defaultValue: "Tabs", bundle: .l10n) }
    static var sectionOpenIn: String { String(localized: "palette.section.openIn", defaultValue: "Open In", bundle: .l10n) }
    static var sectionSettings: String { String(localized: "palette.section.settings", defaultValue: "Change Settings", bundle: .l10n) }
    static var sectionRecentDirectories: String { String(localized: "palette.section.recentDirectories", defaultValue: "Recent Directories", bundle: .l10n) }
    static var commandsTitle: String { String(localized: "palette.page.commands", defaultValue: "Commands", bundle: .l10n) }
    static var searchPlaceholder: String { String(localized: "palette.placeholder.commands", defaultValue: "Search for commands…", bundle: .l10n) }
    static var shortcutsTitle: String { String(localized: "palette.page.shortcuts", defaultValue: "Keyboard Shortcuts", bundle: .l10n) }
    static var shortcutsPlaceholder: String { String(localized: "palette.placeholder.shortcuts", defaultValue: "Search shortcuts by name or keys…", bundle: .l10n) }
    static var workspacesTitle: String { String(localized: "palette.page.workspaces", defaultValue: "Go to Workspace", bundle: .l10n) }
    static func workspaceNotFound(_ id: String) -> String {
        String(localized: "palette.goToWorkspace.notFound", defaultValue: "No workspace \(id).", bundle: .l10n)
    }
    static var workspacesPlaceholder: String { String(localized: "palette.placeholder.workspaces", defaultValue: "Search workspaces…", bundle: .l10n) }
    static var tabsTitle: String { String(localized: "palette.page.tabs", defaultValue: "Go to Tab", bundle: .l10n) }
    static var tabsPlaceholder: String { String(localized: "palette.placeholder.tabs", defaultValue: "Search tabs…", bundle: .l10n) }
    static var openInTitle: String { String(localized: "palette.page.openIn", defaultValue: "Open Current Directory", bundle: .l10n) }
    static var openInPlaceholder: String { String(localized: "palette.placeholder.openIn", defaultValue: "Search apps…", bundle: .l10n) }
    static var settingsTitle: String { String(localized: "palette.page.settings", defaultValue: "Change Settings", bundle: .l10n) }
    static var settingsPlaceholder: String { String(localized: "palette.placeholder.settings", defaultValue: "Search settings…", bundle: .l10n) }
    static var searchActionsPlaceholder: String { String(localized: "palette.placeholder.actions", defaultValue: "Search actions…", bundle: .l10n) }
    /// A title with its state at the end ("Toggle Left Sidebar · On").
    static func titleWithState(_ title: String, _ state: String) -> String {
        String(localized: "palette.toggle.titleWithState", defaultValue: "\(title) · \(state)", bundle: .l10n)
    }
    static var noResults: String { String(localized: "palette.noResults", defaultValue: "No Results", bundle: .l10n) }
    static var create: String { String(localized: "palette.command.create", defaultValue: "Create", bundle: .l10n) }
    static var sectionNoMatch: String { String(localized: "palette.section.noMatch", defaultValue: "Use What You Typed", bundle: .l10n) }
    static func noMatchAskAgent(_ text: String) -> String {
        String(localized: "palette.noMatch.askAgent", defaultValue: "Ask Agent “\(text)”", bundle: .l10n)
    }
    static func noMatchSearchWeb(_ text: String) -> String {
        String(localized: "palette.noMatch.searchWeb", defaultValue: "Search the Web for “\(text)”", bundle: .l10n)
    }
    static func noMatchNewWorkspace(_ text: String) -> String {
        String(localized: "palette.noMatch.newWorkspace", defaultValue: "New Workspace “\(text)”", bundle: .l10n)
    }
    static func noMatchRunCommand(_ text: String) -> String {
        String(localized: "palette.noMatch.runCommand", defaultValue: "Run “\(text)” in a New Workspace", bundle: .l10n)
    }
    static var actions: String { String(localized: "palette.footer.actions", defaultValue: "Actions", bundle: .l10n) }
    static var hideFromPalette: String { String(localized: "palette.action.hideFromPalette", defaultValue: "Hide from Palette", bundle: .l10n) }
    static var showInPalette: String { String(localized: "palette.action.showInPalette", defaultValue: "Show in Palette", bundle: .l10n) }
    static var resetRanking: String { String(localized: "palette.action.resetRanking", defaultValue: "Reset Ranking", bundle: .l10n) }
    static var back: String { String(localized: "palette.back", defaultValue: "Back", bundle: .l10n) }
    static var unbound: String { String(localized: "palette.unbound", defaultValue: "Not bound", bundle: .l10n) }
    static var copyActionID: String { String(localized: "palette.command.copyActionID", defaultValue: "Copy Action ID", bundle: .l10n) }
    static var copyShortcut: String { String(localized: "palette.command.copyShortcut", defaultValue: "Copy Shortcut", bundle: .l10n) }
    static var copyID: String { String(localized: "palette.command.copyID", defaultValue: "Copy ID", bundle: .l10n) }
    static var copyPath: String { String(localized: "palette.command.copyPath", defaultValue: "Copy Path", bundle: .l10n) }
    static var runCommand: String { String(localized: "palette.command.run", defaultValue: "Run Command", bundle: .l10n) }
    static var open: String { String(localized: "palette.command.open", defaultValue: "Open", bundle: .l10n) }
    /// Open Recovered Draft…'s page: its title and its search field.
    static var recoveredDraftsTitle: String {
        String(localized: "palette.recoveredDrafts.title", defaultValue: "Recovered Drafts", bundle: .l10n)
    }
    static var recoveredDraftsPlaceholder: String {
        String(localized: "palette.recoveredDrafts.placeholder", defaultValue: "Find a recovered draft", bundle: .l10n)
    }
    static var submit: String { String(localized: "palette.command.submit", defaultValue: "Submit", bundle: .l10n) }
    static var current: String { String(localized: "palette.accessory.current", defaultValue: "Current", bundle: .l10n) }
    /// The mark on a choice list's value in effect (a team, a theme, a setting's option): a
    /// checkmark, as a menu marks its chosen row. A glyph, not a word, so it needs no translation.
    static let chosenMark = "\u{2713}"
    static var on: String { String(localized: "palette.accessory.on", defaultValue: "On", bundle: .l10n) }
    static var off: String { String(localized: "palette.accessory.off", defaultValue: "Off", bundle: .l10n) }
    static var changeFont: String { String(localized: "palette.setting.changeFont", defaultValue: "Change Font…", bundle: .l10n) }
    static var customValue: String { String(localized: "palette.setting.customValue", defaultValue: "Custom Value…", bundle: .l10n) }
    static var turnOn: String { String(localized: "palette.command.turnOn", defaultValue: "Turn On", bundle: .l10n) }
    static var turnOff: String { String(localized: "palette.command.turnOff", defaultValue: "Turn Off", bundle: .l10n) }
    static var workspaceKeyword: String { String(localized: "palette.keyword.workspace", defaultValue: "workspace", bundle: .l10n) }
    static var tabKeyword: String { String(localized: "palette.keyword.tab", defaultValue: "tab", bundle: .l10n) }
    static var groupKeyword: String { String(localized: "palette.keyword.group", defaultValue: "group", bundle: .l10n) }
    static var paneKeyword: String { String(localized: "palette.keyword.pane", defaultValue: "pane", bundle: .l10n) }
    static var sectionGroups: String { String(localized: "palette.section.groups", defaultValue: "Groups", bundle: .l10n) }
    static var sectionPanes: String { String(localized: "palette.section.panes", defaultValue: "Panes", bundle: .l10n) }
    /// The Search scope's title (the sidebar's Search button) and its field's placeholder.
    static var searchEverythingTitle: String { String(localized: "palette.scope.search", defaultValue: "Search", bundle: .l10n) }
    /// The Chats & agents scope: Search narrowed to agent chats and sessions.
    static var chatsAndAgentsTitle: String { String(localized: "palette.scope.chats", defaultValue: "Chats & agents", bundle: .l10n) }
    static var chatsAndAgentsPlaceholder: String {
        String(localized: "palette.placeholder.chatsAndAgents", defaultValue: "Search chats and agents…", bundle: .l10n)
    }
    static var searchEverythingPlaceholder: String {
        String(localized: "palette.placeholder.searchEverything", defaultValue: "Search workspaces, tabs, history, chats, settings and commands…", bundle: .l10n)
    }
    static var goToAnythingPlaceholder: String {
        String(localized: "palette.placeholder.goToAnything", defaultValue: "Search workspaces, groups, panes and tabs…", bundle: .l10n)
    }
    static var copySessionID: String { String(localized: "palette.command.copySessionID", defaultValue: "Copy Session ID", bundle: .l10n) }
    static var goToGroup: String { String(localized: "palette.command.goToGroup", defaultValue: "Go to Group", bundle: .l10n) }
    static var focusPane: String { String(localized: "palette.command.focusPane", defaultValue: "Focus Pane", bundle: .l10n) }
    static func groupWorkspaceCount(_ count: Int) -> String {
        String(localized: "palette.group.workspaceCount", defaultValue: "Workspaces: \(count)", bundle: .l10n)
    }
    // The kind of a Go to Workspace row, drawn at its right edge.
    static var kindGroup: String { String(localized: "palette.kind.group", defaultValue: "Group", bundle: .l10n) }
    static var kindPane: String { String(localized: "palette.kind.pane", defaultValue: "Pane", bundle: .l10n) }
    static var kindTab: String { String(localized: "palette.kind.tab", defaultValue: "Tab", bundle: .l10n) }
    static var kindTerminal: String { String(localized: "palette.kind.terminal", defaultValue: "Terminal", bundle: .l10n) }
    static var kindBrowser: String { String(localized: "palette.kind.browser", defaultValue: "Browser", bundle: .l10n) }
    static var kindRemoteTerminal: String { String(localized: "palette.kind.remoteTerminal", defaultValue: "Remote Terminal", bundle: .l10n) }
    static var kindAgentChat: String { String(localized: "palette.kind.agentChat", defaultValue: "Agent Chat", bundle: .l10n) }
    static var kindMarkdown: String { String(localized: "palette.kind.markdown", defaultValue: "Markdown", bundle: .l10n) }
    static var kindFile: String { String(localized: "palette.kind.file", defaultValue: "File", bundle: .l10n) }
    static var kindPage: String { String(localized: "palette.kind.page", defaultValue: "Page", bundle: .l10n) }
    static var kindWorkspace: String { String(localized: "palette.kind.workspace", defaultValue: "Workspace", bundle: .l10n) }
    /// A row's kind with its state after it ("Agent Chat · Current"), the kind alone without one.
    static func kindWithState(_ kind: String, state: String?) -> String {
        guard let state else { return kind }
        return String(localized: "palette.kind.withState", defaultValue: "\(kind) · \(state)", bundle: .l10n)
    }
    /// A tab that only repeats its workspace's name, told apart by its kind and place ("Agent Chat 2").
    static func numberedKind(_ kind: String, _ number: Int) -> String {
        String(localized: "palette.kind.numbered", defaultValue: "\(kind) \(number)", bundle: .l10n)
    }
    static var switchToWorkspace: String { String(localized: "palette.command.switchToWorkspace", defaultValue: "Switch to Workspace", bundle: .l10n) }
    static var renameWorkspace: String { String(localized: "palette.command.renameWorkspace", defaultValue: "Rename Workspace…", bundle: .l10n) }
    static var closeWorkspace: String { String(localized: "palette.command.closeWorkspace", defaultValue: "Close Workspace", bundle: .l10n) }
    static var workspaceNamePlaceholder: String { String(localized: "palette.placeholder.workspaceName", defaultValue: "Workspace name", bundle: .l10n) }
    static var switchToTab: String { String(localized: "palette.command.switchToTab", defaultValue: "Switch to Tab", bundle: .l10n) }
    static var renameTab: String { String(localized: "palette.command.renameTab", defaultValue: "Rename Tab…", bundle: .l10n) }
    static var closeTab: String { String(localized: "palette.command.closeTab", defaultValue: "Close Tab", bundle: .l10n) }
    static var tabNamePlaceholder: String { String(localized: "palette.placeholder.tabName", defaultValue: "Tab name", bundle: .l10n) }
    static var choose: String { String(localized: "palette.command.choose", defaultValue: "Choose", bundle: .l10n) }
    static var openInNewWorkspace: String { String(localized: "palette.command.openInNewWorkspace", defaultValue: "Open in New Workspace", bundle: .l10n) }

    static func unreadCount(_ count: Int) -> String {
        String(localized: "palette.accessory.unread", defaultValue: "\(count) unread", bundle: .l10n)
    }
    static func renameTo(_ text: String) -> String {
        String(localized: "palette.renameTo", defaultValue: "Rename to “\(text)”", bundle: .l10n)
    }
    static func openIn(_ app: String) -> String {
        String(localized: "palette.openIn", defaultValue: "Open in \(app)", bundle: .l10n)
    }
    static var added: String { String(localized: "palette.accessory.added", defaultValue: "Added", bundle: .l10n) }
    static func continueWith(_ names: String) -> String {
        String(localized: "palette.members.continue", defaultValue: "Continue with \(names)", bundle: .l10n)
    }
    static func addTyped(_ text: String) -> String {
        String(localized: "palette.members.add", defaultValue: "Add “\(text)”", bundle: .l10n)
    }
    static func removeToken(_ name: String) -> String {
        String(localized: "palette.members.remove", defaultValue: "Remove \(name)", bundle: .l10n)
    }
    static func chooseArgument(_ name: String) -> String {
        String(localized: "palette.chooseArgument", defaultValue: "Choose \(name)…", bundle: .l10n)
    }
    /// The empty prompt of an optional argument the palette asks for (`isAskedInPalette`).
    static func optionalArgument(_ name: String) -> String {
        String(localized: "palette.optionalArgument", defaultValue: "\(name) (optional)", bundle: .l10n)
    }
    static func submitTextFormat(title: String, text: String) -> String {
        String(localized: "palette.submitText", defaultValue: "\(title) “\(text)”", bundle: .l10n)
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
    static var sectionGoTo: String { String(localized: "palette.section.goTo", defaultValue: "Go To", bundle: .l10n) }
    static var kindFolder: String { String(localized: "palette.kind.folder", defaultValue: "Folder", bundle: .l10n) }
    static func goToOpen(_ place: String) -> String { String(localized: "palette.goTo.open", defaultValue: "Open \(place)", bundle: .l10n) }
    static var goToFolderHint: String { String(localized: "palette.goTo.folderHint", defaultValue: "New terminal tab in this folder", bundle: .l10n) }
    static var goToAskCommand: String { String(localized: "palette.goTo.askCommand", defaultValue: "Ask Agent", bundle: .l10n) }
    static func goToAsk(_ place: String) -> String { String(localized: "palette.goTo.ask", defaultValue: "Ask Agent about \(place)", bundle: .l10n) }
    static func goToAskWithPrompt(_ place: String, _ prompt: String) -> String {
        String(localized: "palette.goTo.askWithPrompt", defaultValue: "Ask Agent about \(place): \(prompt)", bundle: .l10n)
    }
    static var goToAskHint: String { String(localized: "palette.goTo.askHint", defaultValue: "New agent chat; type your prompt", bundle: .l10n) }
    static var goToAskSendsHint: String { String(localized: "palette.goTo.askSendsHint", defaultValue: "New agent chat; sends this prompt", bundle: .l10n) }
    static var goToCopyURL: String { String(localized: "palette.goTo.copyURL", defaultValue: "Copy URL", bundle: .l10n) }
}
