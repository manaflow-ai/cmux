import CmuxNextActions
import Foundation

/// Localized strings for the palette. Keys live in Localizable.xcstrings (en, ja).
nonisolated enum PaletteStrings {
    static var sectionRecent: String { String(localized: "palette.section.recent", defaultValue: "Recent", bundle: .module) }
    static var sectionWorkspaces: String { String(localized: "palette.section.workspaces", defaultValue: "Workspaces", bundle: .module) }
    static var sectionTabs: String { String(localized: "palette.section.tabs", defaultValue: "Tabs", bundle: .module) }
    static var sectionOpenIn: String { String(localized: "palette.section.openIn", defaultValue: "Open In", bundle: .module) }
    static var sectionSettings: String { String(localized: "palette.section.settings", defaultValue: "Toggle Setting", bundle: .module) }
    static var sectionRecentDirectories: String { String(localized: "palette.section.recentDirectories", defaultValue: "Recent Directories", bundle: .module) }
    static var commandsTitle: String { String(localized: "palette.page.commands", defaultValue: "Commands", bundle: .module) }
    static var searchPlaceholder: String { String(localized: "palette.placeholder.commands", defaultValue: "Search for commands…", bundle: .module) }
    static var shortcutsTitle: String { String(localized: "palette.page.shortcuts", defaultValue: "Keyboard Shortcuts", bundle: .module) }
    static var shortcutsPlaceholder: String { String(localized: "palette.placeholder.shortcuts", defaultValue: "Search shortcuts by name or keys…", bundle: .module) }
    static var workspacesTitle: String { String(localized: "palette.page.workspaces", defaultValue: "Go to Workspace", bundle: .module) }
    static var workspacesPlaceholder: String { String(localized: "palette.placeholder.workspaces", defaultValue: "Search workspaces…", bundle: .module) }
    static var tabsTitle: String { String(localized: "palette.page.tabs", defaultValue: "Go to Tab", bundle: .module) }
    static var tabsPlaceholder: String { String(localized: "palette.placeholder.tabs", defaultValue: "Search tabs…", bundle: .module) }
    static var openInTitle: String { String(localized: "palette.page.openIn", defaultValue: "Open Current Directory", bundle: .module) }
    static var openInPlaceholder: String { String(localized: "palette.placeholder.openIn", defaultValue: "Search apps…", bundle: .module) }
    static var settingsTitle: String { String(localized: "palette.page.settings", defaultValue: "Toggle Setting", bundle: .module) }
    static var settingsPlaceholder: String { String(localized: "palette.placeholder.settings", defaultValue: "Search settings…", bundle: .module) }
    static var searchActionsPlaceholder: String { String(localized: "palette.placeholder.actions", defaultValue: "Search actions…", bundle: .module) }
    static var noResults: String { String(localized: "palette.noResults", defaultValue: "No Results", bundle: .module) }
    static var noResultsHint: String { String(localized: "palette.noResults.hint", defaultValue: "Try a different search, or press Esc to go back.", bundle: .module) }
    static var actions: String { String(localized: "palette.footer.actions", defaultValue: "Actions", bundle: .module) }
    static var back: String { String(localized: "palette.back", defaultValue: "Back", bundle: .module) }
    static var unbound: String { String(localized: "palette.unbound", defaultValue: "Not bound", bundle: .module) }
    static var copyActionID: String { String(localized: "palette.command.copyActionID", defaultValue: "Copy Action ID", bundle: .module) }
    static var copyShortcut: String { String(localized: "palette.command.copyShortcut", defaultValue: "Copy Shortcut", bundle: .module) }
    static var copyID: String { String(localized: "palette.command.copyID", defaultValue: "Copy ID", bundle: .module) }
    static var copyPath: String { String(localized: "palette.command.copyPath", defaultValue: "Copy Path", bundle: .module) }
    static var runCommand: String { String(localized: "palette.command.run", defaultValue: "Run Command", bundle: .module) }
    static var open: String { String(localized: "palette.command.open", defaultValue: "Open", bundle: .module) }
    static var submit: String { String(localized: "palette.command.submit", defaultValue: "Submit", bundle: .module) }
    static var current: String { String(localized: "palette.accessory.current", defaultValue: "Current", bundle: .module) }
    static var on: String { String(localized: "palette.accessory.on", defaultValue: "On", bundle: .module) }
    static var off: String { String(localized: "palette.accessory.off", defaultValue: "Off", bundle: .module) }
    static var customValue: String { String(localized: "palette.setting.customValue", defaultValue: "Custom Value…", bundle: .module) }
    static var turnOn: String { String(localized: "palette.command.turnOn", defaultValue: "Turn On", bundle: .module) }
    static var turnOff: String { String(localized: "palette.command.turnOff", defaultValue: "Turn Off", bundle: .module) }
    static var workspaceKeyword: String { String(localized: "palette.keyword.workspace", defaultValue: "workspace", bundle: .module) }
    static var tabKeyword: String { String(localized: "palette.keyword.tab", defaultValue: "tab", bundle: .module) }
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
}
