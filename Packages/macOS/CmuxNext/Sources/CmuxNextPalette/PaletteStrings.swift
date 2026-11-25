import CmuxNextActions
import Foundation

/// Localized strings for the palette. Keys live in Localizable.xcstrings (en, ja).
nonisolated enum PaletteStrings {
    static var target: String { String(localized: "palette.target", defaultValue: "Choose a target", bundle: .localizedModule) }
    static var chooseTarget: String { String(localized: "palette.target.search", defaultValue: "Search…", bundle: .localizedModule) }
    static var sectionPinned: String { String(localized: "palette.section.pinned", defaultValue: "Pinned", bundle: .localizedModule) }
    static var sectionSuggested: String { String(localized: "palette.section.suggested", defaultValue: "Suggested", bundle: .localizedModule) }
    static var sectionRecent: String { String(localized: "palette.section.recent", defaultValue: "Recent", bundle: .localizedModule) }
    static var sectionWorkspaces: String { String(localized: "palette.section.workspaces", defaultValue: "Workspaces", bundle: .localizedModule) }
    static var sectionTabs: String { String(localized: "palette.section.tabs", defaultValue: "Tabs", bundle: .localizedModule) }
    static var sectionOpenIn: String { String(localized: "palette.section.openIn", defaultValue: "Open In", bundle: .localizedModule) }
    static var sectionSettings: String { String(localized: "palette.section.settings", defaultValue: "Change Settings", bundle: .localizedModule) }
    static var sectionRecentDirectories: String { String(localized: "palette.section.recentDirectories", defaultValue: "Recent Directories", bundle: .localizedModule) }
    static var commandsTitle: String { String(localized: "palette.page.commands", defaultValue: "Commands", bundle: .localizedModule) }
    static var searchPlaceholder: String { String(localized: "palette.placeholder.commands", defaultValue: "Search for commands…", bundle: .localizedModule) }
    static var shortcutsTitle: String { String(localized: "palette.page.shortcuts", defaultValue: "Keyboard Shortcuts", bundle: .localizedModule) }
    static var shortcutsPlaceholder: String { String(localized: "palette.placeholder.shortcuts", defaultValue: "Search shortcuts by name or keys…", bundle: .localizedModule) }
    static var workspacesTitle: String { String(localized: "palette.page.workspaces", defaultValue: "Go to Workspace", bundle: .localizedModule) }
    static func workspaceNotFound(_ id: String) -> String {
        String(localized: "palette.goToWorkspace.notFound", defaultValue: "No workspace \(id).", bundle: .localizedModule)
    }
    static var workspacesPlaceholder: String { String(localized: "palette.placeholder.workspaces", defaultValue: "Search workspaces…", bundle: .localizedModule) }
    static var tabsTitle: String { String(localized: "palette.page.tabs", defaultValue: "Go to Tab", bundle: .localizedModule) }
    static var tabsPlaceholder: String { String(localized: "palette.placeholder.tabs", defaultValue: "Search tabs…", bundle: .localizedModule) }
    static var openInTitle: String { String(localized: "palette.page.openIn", defaultValue: "Open Current Directory", bundle: .localizedModule) }
    static var openInPlaceholder: String { String(localized: "palette.placeholder.openIn", defaultValue: "Search apps…", bundle: .localizedModule) }
    static var settingsTitle: String { String(localized: "palette.page.settings", defaultValue: "Change Settings", bundle: .localizedModule) }
    static var settingsPlaceholder: String { String(localized: "palette.placeholder.settings", defaultValue: "Search settings…", bundle: .localizedModule) }
    static var searchActionsPlaceholder: String { String(localized: "palette.placeholder.actions", defaultValue: "Search actions…", bundle: .localizedModule) }
    /// A title with its state at the end ("Toggle Left Sidebar · On").
    static func titleWithState(_ title: String, _ state: String) -> String {
        String(localized: "palette.toggle.titleWithState", defaultValue: "\(title) · \(state)", bundle: .localizedModule)
    }
    static var noResults: String { String(localized: "palette.noResults", defaultValue: "No Results", bundle: .localizedModule) }
    static var create: String { String(localized: "palette.command.create", defaultValue: "Create", bundle: .localizedModule) }
    static var sectionNoMatch: String { String(localized: "palette.section.noMatch", defaultValue: "Use What You Typed", bundle: .localizedModule) }
    static func noMatchAskAgent(_ text: String) -> String {
        String(localized: "palette.noMatch.askAgent", defaultValue: "Ask Agent “\(text)”", bundle: .localizedModule)
    }
    static func noMatchSearchWeb(_ text: String) -> String {
        String(localized: "palette.noMatch.searchWeb", defaultValue: "Search the Web for “\(text)”", bundle: .localizedModule)
    }
    static func noMatchNewWorkspace(_ text: String) -> String {
        String(localized: "palette.noMatch.newWorkspace", defaultValue: "New Workspace “\(text)”", bundle: .localizedModule)
    }
    static func noMatchRunCommand(_ text: String) -> String {
        String(localized: "palette.noMatch.runCommand", defaultValue: "Run “\(text)” in a New Workspace", bundle: .localizedModule)
    }
    static var actions: String { String(localized: "palette.footer.actions", defaultValue: "Actions", bundle: .localizedModule) }
    // The preview pane's Information list (`experiments.palettePreview`): its heading and each fact's label.
    static var previewInformation: String { String(localized: "palette.preview.information", defaultValue: "Information", bundle: .localizedModule) }
    static var factName: String { String(localized: "palette.preview.fact.name", defaultValue: "Name", bundle: .localizedModule) }
    static var factTitle: String { String(localized: "palette.preview.fact.title", defaultValue: "Title", bundle: .localizedModule) }
    static var factKind: String { String(localized: "palette.preview.fact.kind", defaultValue: "Kind", bundle: .localizedModule) }
    static var factDirectory: String { String(localized: "palette.preview.fact.directory", defaultValue: "Directory", bundle: .localizedModule) }
    static var factAddress: String { String(localized: "palette.preview.fact.address", defaultValue: "Address", bundle: .localizedModule) }
    static var factWorkspace: String { String(localized: "palette.preview.fact.workspace", defaultValue: "Workspace", bundle: .localizedModule) }
    static var factGroup: String { String(localized: "palette.preview.fact.group", defaultValue: "Group", bundle: .localizedModule) }
    static var factMachine: String { String(localized: "palette.preview.fact.machine", defaultValue: "Machine", bundle: .localizedModule) }
    static var factTabs: String { String(localized: "palette.preview.fact.tabs", defaultValue: "Tabs", bundle: .localizedModule) }
    static var factAgents: String { String(localized: "palette.preview.fact.agents", defaultValue: "Agents", bundle: .localizedModule) }
    static var factAgent: String { String(localized: "palette.preview.fact.agent", defaultValue: "Agent", bundle: .localizedModule) }
    static var factBranch: String { String(localized: "palette.preview.fact.branch", defaultValue: "Branch", bundle: .localizedModule) }
    static var factStatus: String { String(localized: "palette.preview.fact.status", defaultValue: "Status", bundle: .localizedModule) }
    static var factSession: String { String(localized: "palette.preview.fact.session", defaultValue: "Session", bundle: .localizedModule) }
    static var factLastActive: String { String(localized: "palette.preview.fact.lastActive", defaultValue: "Last Active", bundle: .localizedModule) }
    static var factCommand: String { String(localized: "palette.preview.fact.command", defaultValue: "Command", bundle: .localizedModule) }
    static var factShortcut: String { String(localized: "palette.preview.fact.shortcut", defaultValue: "Shortcut", bundle: .localizedModule) }
    static var factCategory: String { String(localized: "palette.preview.fact.category", defaultValue: "Category", bundle: .localizedModule) }
    static var factDescription: String { String(localized: "palette.preview.fact.description", defaultValue: "Description", bundle: .localizedModule) }
    static var factDetails: String { String(localized: "palette.preview.fact.details", defaultValue: "Details", bundle: .localizedModule) }
    /// Between a chord's two strokes on its keycaps: ⌘ J then S.
    static var keycapThen: String { String(localized: "palette.keycap.then", defaultValue: "then", bundle: .localizedModule) }
    static var hideFromPalette: String { String(localized: "palette.action.hideFromPalette", defaultValue: "Hide from Palette", bundle: .localizedModule) }
    static var showInPalette: String { String(localized: "palette.action.showInPalette", defaultValue: "Show in Palette", bundle: .localizedModule) }
    static var resetRanking: String { String(localized: "palette.action.resetRanking", defaultValue: "Reset Ranking", bundle: .localizedModule) }
    static var back: String { String(localized: "palette.back", defaultValue: "Back", bundle: .localizedModule) }
    static var unbound: String { String(localized: "palette.unbound", defaultValue: "Not bound", bundle: .localizedModule) }
    static var copyActionID: String { String(localized: "palette.command.copyActionID", defaultValue: "Copy Action ID", bundle: .localizedModule) }
    static var copyShortcut: String { String(localized: "palette.command.copyShortcut", defaultValue: "Copy Shortcut", bundle: .localizedModule) }
    static var copyID: String { String(localized: "palette.command.copyID", defaultValue: "Copy ID", bundle: .localizedModule) }
    static var copyPath: String { String(localized: "palette.command.copyPath", defaultValue: "Copy Path", bundle: .localizedModule) }
    static var runCommand: String { String(localized: "palette.command.run", defaultValue: "Run Command", bundle: .localizedModule) }
    static var open: String { String(localized: "palette.command.open", defaultValue: "Open", bundle: .localizedModule) }
    /// Open Recovered Draft…'s page: its title and its search field.
    static var recoveredDraftsTitle: String {
        String(localized: "palette.recoveredDrafts.title", defaultValue: "Recovered Drafts", bundle: .localizedModule)
    }
    static var recoveredDraftsPlaceholder: String {
        String(localized: "palette.recoveredDrafts.placeholder", defaultValue: "Find a recovered draft", bundle: .localizedModule)
    }
    static var submit: String { String(localized: "palette.command.submit", defaultValue: "Submit", bundle: .localizedModule) }
    static var current: String { String(localized: "palette.accessory.current", defaultValue: "Current", bundle: .localizedModule) }
    /// The mark on a choice list's value in effect (a team, a theme, a setting's option): a
    /// checkmark, as a menu marks its chosen row. A glyph, not a word, so it needs no translation.
    static let chosenMark = "\u{2713}"
    static var on: String { String(localized: "palette.accessory.on", defaultValue: "On", bundle: .localizedModule) }
    static var off: String { String(localized: "palette.accessory.off", defaultValue: "Off", bundle: .localizedModule) }
    static var changeFont: String { String(localized: "palette.setting.changeFont", defaultValue: "Change Font…", bundle: .localizedModule) }
    static var customValue: String { String(localized: "palette.setting.customValue", defaultValue: "Custom Value…", bundle: .localizedModule) }
    static var turnOn: String { String(localized: "palette.command.turnOn", defaultValue: "Turn On", bundle: .localizedModule) }
    static var turnOff: String { String(localized: "palette.command.turnOff", defaultValue: "Turn Off", bundle: .localizedModule) }
    static var workspaceKeyword: String { String(localized: "palette.keyword.workspace", defaultValue: "workspace", bundle: .localizedModule) }
    static var tabKeyword: String { String(localized: "palette.keyword.tab", defaultValue: "tab", bundle: .localizedModule) }
    static var groupKeyword: String { String(localized: "palette.keyword.group", defaultValue: "group", bundle: .localizedModule) }
    static var paneKeyword: String { String(localized: "palette.keyword.pane", defaultValue: "pane", bundle: .localizedModule) }
    static var sectionGroups: String { String(localized: "palette.section.groups", defaultValue: "Groups", bundle: .localizedModule) }
    static var sectionPanes: String { String(localized: "palette.section.panes", defaultValue: "Panes", bundle: .localizedModule) }
    /// The palette v2 look's group headers and rail (`PaletteV2Group`); Workspaces and Commands reuse their titles.
    static var v2GroupSessions: String { String(localized: "palette.v2.group.sessions", defaultValue: "Sessions", bundle: .localizedModule) }
    static var v2GroupAgents: String { String(localized: "palette.v2.group.agents", defaultValue: "Agents", bundle: .localizedModule) }
    static var v2RailAll: String { String(localized: "palette.v2.rail.all", defaultValue: "All", bundle: .localizedModule) }
    /// The Search scope's title (the sidebar's Search button) and its field's placeholder.
    static var searchEverythingTitle: String { String(localized: "palette.scope.search", defaultValue: "Search", bundle: .localizedModule) }
    /// The Chats & agents scope: Search narrowed to agent chats and sessions.
    static var chatsAndAgentsTitle: String { String(localized: "palette.scope.chats", defaultValue: "Chats & agents", bundle: .localizedModule) }
    static var chatsAndAgentsPlaceholder: String {
        String(localized: "palette.placeholder.chatsAndAgents", defaultValue: "Search chats and agents…", bundle: .localizedModule)
    }
    static var searchEverythingPlaceholder: String {
        String(localized: "palette.placeholder.searchEverything", defaultValue: "Search workspaces, tabs, history, chats, settings and commands…", bundle: .localizedModule)
    }
    /// The line under Search's field: how to search one kind of row.
    static var searchFiltersHint: String {
        String(localized: "palette.hint.searchFilters", defaultValue: "Narrow with in:tabs, in:history, in:settings, or leave a kind out with -in:chats", bundle: .module)
    }
    static var goToAnythingPlaceholder: String {
        String(localized: "palette.placeholder.goToAnything", defaultValue: "Search workspaces, groups, panes and tabs…", bundle: .localizedModule)
    }
    static var copySessionID: String { String(localized: "palette.command.copySessionID", defaultValue: "Copy Session ID", bundle: .localizedModule) }
    static var goToGroup: String { String(localized: "palette.command.goToGroup", defaultValue: "Go to Group", bundle: .localizedModule) }
    static var focusPane: String { String(localized: "palette.command.focusPane", defaultValue: "Focus Pane", bundle: .localizedModule) }
    static func groupWorkspaceCount(_ count: Int) -> String {
        String(localized: "palette.group.workspaceCount", defaultValue: "Workspaces: \(count)", bundle: .localizedModule)
    }
    // The kind of a Go to Workspace row, drawn at its right edge.
    static var kindGroup: String { String(localized: "palette.kind.group", defaultValue: "Group", bundle: .localizedModule) }
    static var kindPane: String { String(localized: "palette.kind.pane", defaultValue: "Pane", bundle: .localizedModule) }
    static var kindTab: String { String(localized: "palette.kind.tab", defaultValue: "Tab", bundle: .localizedModule) }
    static var kindTerminal: String { String(localized: "palette.kind.terminal", defaultValue: "Terminal", bundle: .localizedModule) }
    static var kindBrowser: String { String(localized: "palette.kind.browser", defaultValue: "Browser", bundle: .localizedModule) }
    static var kindRemoteTerminal: String { String(localized: "palette.kind.remoteTerminal", defaultValue: "Remote Terminal", bundle: .localizedModule) }
    static var kindAgentChat: String { String(localized: "palette.kind.agentChat", defaultValue: "Agent Chat", bundle: .localizedModule) }
    static var kindMarkdown: String { String(localized: "palette.kind.markdown", defaultValue: "Markdown", bundle: .localizedModule) }
    static var kindFile: String { String(localized: "palette.kind.file", defaultValue: "File", bundle: .localizedModule) }
    static var kindPage: String { String(localized: "palette.kind.page", defaultValue: "Page", bundle: .localizedModule) }
    static var kindWorkspace: String { String(localized: "palette.kind.workspace", defaultValue: "Workspace", bundle: .localizedModule) }
    /// A row's kind with its state after it ("Agent Chat · Current"), the kind alone without one.
    static func kindWithState(_ kind: String, state: String?) -> String {
        guard let state else { return kind }
        return String(localized: "palette.kind.withState", defaultValue: "\(kind) · \(state)", bundle: .localizedModule)
    }
    /// A tab that only repeats its workspace's name, told apart by its kind and place ("Agent Chat 2").
    static func numberedKind(_ kind: String, _ number: Int) -> String {
        String(localized: "palette.kind.numbered", defaultValue: "\(kind) \(number)", bundle: .localizedModule)
    }
    static var switchToWorkspace: String { String(localized: "palette.command.switchToWorkspace", defaultValue: "Switch to Workspace", bundle: .localizedModule) }
    static var renameWorkspace: String { String(localized: "palette.command.renameWorkspace", defaultValue: "Rename Workspace…", bundle: .localizedModule) }
    static var closeWorkspace: String { String(localized: "palette.command.closeWorkspace", defaultValue: "Close Workspace", bundle: .localizedModule) }
    static var workspaceNamePlaceholder: String { String(localized: "palette.placeholder.workspaceName", defaultValue: "Workspace name", bundle: .localizedModule) }
    static var switchToTab: String { String(localized: "palette.command.switchToTab", defaultValue: "Switch to Tab", bundle: .localizedModule) }
    static var renameTab: String { String(localized: "palette.command.renameTab", defaultValue: "Rename Tab…", bundle: .localizedModule) }
    static var closeTab: String { String(localized: "palette.command.closeTab", defaultValue: "Close Tab", bundle: .localizedModule) }
    static var tabNamePlaceholder: String { String(localized: "palette.placeholder.tabName", defaultValue: "Tab name", bundle: .localizedModule) }
    static var choose: String { String(localized: "palette.command.choose", defaultValue: "Choose", bundle: .localizedModule) }
    static var openInNewWorkspace: String { String(localized: "palette.command.openInNewWorkspace", defaultValue: "Open in New Workspace", bundle: .localizedModule) }

    static func unreadCount(_ count: Int) -> String {
        String(localized: "palette.accessory.unread", defaultValue: "\(count) unread", bundle: .localizedModule)
    }
    static func renameTo(_ text: String) -> String {
        String(localized: "palette.renameTo", defaultValue: "Rename to “\(text)”", bundle: .localizedModule)
    }
    static func openIn(_ app: String) -> String {
        String(localized: "palette.openIn", defaultValue: "Open in \(app)", bundle: .localizedModule)
    }
    static var added: String { String(localized: "palette.accessory.added", defaultValue: "Added", bundle: .localizedModule) }
    static func continueWith(_ names: String) -> String {
        String(localized: "palette.members.continue", defaultValue: "Continue with \(names)", bundle: .localizedModule)
    }
    static func addTyped(_ text: String) -> String {
        String(localized: "palette.members.add", defaultValue: "Add “\(text)”", bundle: .localizedModule)
    }
    static func removeToken(_ name: String) -> String {
        String(localized: "palette.members.remove", defaultValue: "Remove \(name)", bundle: .localizedModule)
    }
    static func chooseArgument(_ name: String) -> String {
        String(localized: "palette.chooseArgument", defaultValue: "Choose \(name)…", bundle: .localizedModule)
    }
    /// The empty prompt of an optional argument the palette asks for (`isAskedInPalette`).
    static func optionalArgument(_ name: String) -> String {
        String(localized: "palette.optionalArgument", defaultValue: "\(name) (optional)", bundle: .localizedModule)
    }
    static func submitTextFormat(title: String, text: String) -> String {
        String(localized: "palette.submitText", defaultValue: "\(title) “\(text)”", bundle: .localizedModule)
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
    static var sectionGoTo: String { String(localized: "palette.section.goTo", defaultValue: "Go To", bundle: .localizedModule) }
    static var kindFolder: String { String(localized: "palette.kind.folder", defaultValue: "Folder", bundle: .localizedModule) }
    /// The footer's Return label naming the row it acts on: "Switch to Tab “Fix the login bug”".
    static func primaryNamingRow(_ verb: String, _ row: String) -> String {
        String(localized: "palette.footer.primaryNamingRow", defaultValue: "\(verb) “\(row)”", bundle: .localizedModule)
    }
    static func goToOpen(_ place: String) -> String { String(localized: "palette.goTo.open", defaultValue: "Open \(place)", bundle: .localizedModule) }
    static var goToFolderHint: String { String(localized: "palette.goTo.folderHint", defaultValue: "New terminal tab in this folder", bundle: .localizedModule) }
    static var goToAskCommand: String { String(localized: "palette.goTo.askCommand", defaultValue: "Ask Agent", bundle: .localizedModule) }
    static func goToAsk(_ place: String) -> String { String(localized: "palette.goTo.ask", defaultValue: "Ask Agent about \(place)", bundle: .localizedModule) }
    static func goToAskWithPrompt(_ place: String, _ prompt: String) -> String {
        String(localized: "palette.goTo.askWithPrompt", defaultValue: "Ask Agent about \(place): \(prompt)", bundle: .localizedModule)
    }
    static var goToAskHint: String { String(localized: "palette.goTo.askHint", defaultValue: "New agent chat; type your prompt", bundle: .localizedModule) }
    static var goToAskSendsHint: String { String(localized: "palette.goTo.askSendsHint", defaultValue: "New agent chat; sends this prompt", bundle: .localizedModule) }
    static var goToCopyURL: String { String(localized: "palette.goTo.copyURL", defaultValue: "Copy URL", bundle: .localizedModule) }
}

// The palette v2 look's Esc chip and scope bar (`PaletteV2Look`): segments, typed token suggestions and chips.
// Nonisolated: the scope bar's segment and token values read them off the main actor too.
nonisolated extension PaletteStrings {
    static var escKey: String { String(localized: "palette.escChip.key", defaultValue: "Esc", bundle: .localizedModule) }
    static var closePalette: String { String(localized: "palette.escChip.close", defaultValue: "Close Palette", bundle: .localizedModule) }
    static var scopeAll: String { String(localized: "palette.scopeBar.all", defaultValue: "All", bundle: .localizedModule) }
    static var scopeThisWorkspace: String { String(localized: "palette.scopeBar.thisWorkspace", defaultValue: "This Workspace", bundle: .localizedModule) }
    static var scopeSessions: String { String(localized: "palette.scopeBar.sessions", defaultValue: "Sessions", bundle: .localizedModule) }
    static var thisWorkspacePlaceholder: String {
        String(localized: "palette.scopeBar.thisWorkspace.placeholder", defaultValue: "Search this workspace…", bundle: .localizedModule)
    }
    static var sessionsPlaceholder: String {
        String(localized: "palette.scopeBar.sessions.placeholder", defaultValue: "Search sessions…", bundle: .localizedModule)
    }
    static var sectionSuggestions: String { String(localized: "palette.scopeToken.suggestions", defaultValue: "Suggestions", bundle: .localizedModule) }
    static var sessionContains: String { String(localized: "palette.scopeToken.sessionContains", defaultValue: "Session contains:", bundle: .localizedModule) }
    static var workspaceContains: String {
        String(localized: "palette.scopeToken.workspaceContains", defaultValue: "Workspace contains:", bundle: .localizedModule)
    }
    static var addScopeToken: String { String(localized: "palette.scopeToken.add", defaultValue: "Filter", bundle: .localizedModule) }
    static func sessionTokenChip(_ text: String) -> String {
        String(localized: "palette.scopeToken.sessionChip", defaultValue: "Session: \(text)", bundle: .localizedModule)
    }
    static func workspaceTokenChip(_ text: String) -> String {
        String(localized: "palette.scopeToken.workspaceChip", defaultValue: "Workspace: \(text)", bundle: .localizedModule)
    }
}
