import Foundation

/// Text of the Settings window (Localizable.xcstrings in this module).
/// Setting titles live with the schema in CmuxNextSettings.
nonisolated enum SettingsWindowStrings {
    static var windowTitle: String { text("settingsWindow.title", "Settings") }
    static var searchPlaceholder: String { text("settingsWindow.search", "Search") }
    static var noResults: String { text("settingsWindow.noResults", "No settings match.") }
    static var reset: String { text("settingsWindow.reset", "Reset") }
    static var managedByOrganization: String { text("settingsWindow.managed.device", "Managed by your organization") }
    static func managedByTeam(_ team: String) -> String { format("settingsWindow.managed.team", "Managed by %@", team) }
    static func defaultIs(_ value: String) -> String { format("settingsWindow.defaultIs", "Default: %@", value) }
    static func writeFailed(_ reason: String) -> String { format("settingsWindow.writeFailed", "Could not write cmux.json: %@", reason) }
    static var custom: String { text("settingsWindow.custom", "Custom") }
    static var add: String { text("settingsWindow.add", "Add") }
    static var remove: String { text("settingsWindow.remove", "Remove") }
    static var hostPlaceholder: String { text("settingsWindow.hostPlaceholder", "example.com") }
    static var quietFrom: String { text("settingsWindow.quietFrom", "From") }
    static var quietTo: String { text("settingsWindow.quietTo", "To") }
    static var soundDefault: String { text("settingsWindow.soundDefault", "Default") }
    static var soundNone: String { text("settingsWindow.soundNone", "None") }
    static var blankPage: String { text("settingsWindow.blankPage", "Blank page") }
    static var themeTitle: String { text("settingsWindow.theme", "Theme") }
    static var themeLevelRoom: String { text("settingsWindow.themeLevel.room", "Room") }
    static var themeLevelWorkspace: String { text("settingsWindow.themeLevel.workspace", "Workspace") }
    static var themeLevelTerminal: String { text("settingsWindow.themeLevel.terminal", "Terminal") }
    static var themeSearch: String { text("settingsWindow.themeSearch", "Search Ghostty themes") }
    static var themeUseConfig: String { text("settingsWindow.themeUseConfig", "Use Ghostty Config") }
    static func themeUse(_ spec: String) -> String { format("settingsWindow.themeUse", "Use “%@”", spec) }
    static var themePickerTitle: String { text("settingsWindow.themePicker", "Themes") }
    static var themeBody: String { text("settingsWindow.themeBody", "Colors come from your Ghostty theme and follow it live.") }
    static var terminalBody: String {
        text("settingsWindow.terminalBody.options", "Cursor, keybinds and other terminal options are Ghostty settings.")
    }
    static var moreThemes: String { text("settingsWindow.moreThemes", "More Themes") }
    static var ghosttyConfig: String { text("settingsWindow.ghosttyConfig", "Ghostty Config") }
    static var shellIntegration: String { text("settingsWindow.shellIntegration", "Shell Integration") }
    static var shellIntegrationUnknown: String { text("settingsWindow.shellIntegrationUnknown", "Set by the Ghostty config") }
    static var keyboardHint: String { text("settingsWindow.keyboardHint", "Click a shortcut to record a new one. Esc cancels.") }
    static var conflict: String { text("settingsWindow.conflict", "Another action uses this shortcut in the same place.") }
    static var roomsUnavailable: String { text("settingsWindow.roomsUnavailable", "Rooms need a newer cmux-tui on this Mac.") }
    static var roomsEmpty: String { text("settingsWindow.roomsEmpty", "No rooms yet.") }
    static var browserProfilesTitle: String { text("settingsWindow.browserProfiles", "Browser Profiles") }
    static var browserProfilesHint: String {
        text("settingsWindow.browserProfilesHint", "Each profile has its own cookies, logins, history, extensions and site permissions.")
    }
    static var newBrowserProfile: String { text("settingsWindow.newBrowserProfile", "New Browser Profile") }
    static var profileName: String { text("settingsWindow.profileName", "Name") }
    static var profileColor: String { text("settingsWindow.profileColor", "Color") }
    static var profileIcon: String { text("settingsWindow.profileIcon", "Icon") }
    static var deleteProfile: String { text("settingsWindow.deleteProfile", "Delete Profile and Data…") }
    static var machinesEmpty: String { text("settingsWindow.machinesEmpty", "No saved machines.") }
    static var settingsFile: String { text("settingsWindow.settingsFile", "Settings File") }
    static var showInFinder: String { text("settingsWindow.showInFinder", "Show in Finder") }
    static var resetAll: String { text("settingsWindow.resetAll", "Reset All Settings…") }
    static var resetAllTitle: String { text("settingsWindow.resetAllTitle", "Reset all settings?") }
    static var resetAllBody: String {
        text("settingsWindow.resetAllBody", "Every setting and shortcut in cmux.json goes back to its default. Custom actions stay.")
    }
    static var cancel: String { text("settingsWindow.cancel", "Cancel") }
    static var problems: String { text("settingsWindow.problems", "Problems in cmux.json") }
    static var noProblems: String { text("settingsWindow.noProblems", "No problems.") }
    static func minutes(_ value: String) -> String { format("settingsWindow.minutes", "%@ min", value) }
    static func seconds(_ value: String) -> String { format("settingsWindow.seconds", "%@ s", value) }
    static func points(_ value: String) -> String { format("settingsWindow.points", "%@ pt", value) }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ args: any CVarArg...) -> String {
        String(format: text(key, value), locale: Locale.current, arguments: args)
    }
}
