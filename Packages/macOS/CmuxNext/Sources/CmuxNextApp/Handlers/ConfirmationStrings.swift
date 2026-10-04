import Foundation

/// Confirmation sheet text for destructive actions (Resources/Handlers.xcstrings).
enum ConfirmationStrings {
    static var cancel: String {
        String(localized: "confirm.button.cancel", defaultValue: "Cancel", table: "Handlers", bundle: .module)
    }

    static var close: String {
        String(localized: "confirm.button.close", defaultValue: "Close", table: "Handlers", bundle: .module)
    }

    static var delete: String {
        String(localized: "confirm.button.delete", defaultValue: "Delete", table: "Handlers", bundle: .module)
    }

    static var quit: String {
        String(localized: "confirm.button.quit", defaultValue: "Quit", table: "Handlers", bundle: .module)
    }

    static var closeIncognitoWindowTitle: String {
        String(localized: "confirm.closeIncognitoWindow.title", defaultValue: "Close this incognito window?", table: "Handlers", bundle: .module)
    }

    static var quitIncognitoTitle: String {
        String(localized: "confirm.quitIncognito.title", defaultValue: "Quit and close incognito windows?", table: "Handlers", bundle: .module)
    }

    static func incognitoBody(_ programs: String) -> String {
        String(localized: "confirm.incognito.body",
               defaultValue: "Still running: \(programs). Closing ends these processes and deletes the incognito browser data.",
               table: "Handlers", bundle: .module)
    }

    static func closeWorkspaceTitle(_ name: String) -> String {
        String(localized: "confirm.closeWorkspace.title", defaultValue: "Close “\(name)”?", table: "Handlers", bundle: .module)
    }

    static func closeWorkspaceBody(_ programs: String) -> String {
        String(localized: "confirm.closeWorkspace.body",
               defaultValue: "Still running: \(programs). Closing the workspace ends these processes.", table: "Handlers", bundle: .module)
    }

    static func deleteGroupTitle(_ name: String) -> String {
        String(localized: "confirm.deleteGroup.title", defaultValue: "Delete the group “\(name)”?", table: "Handlers", bundle: .module)
    }

    static func closeGroupWorkspacesTitle(_ name: String) -> String {
        String(localized: "confirm.closeGroupWorkspaces.title", defaultValue: "Close every workspace in “\(name)”?", table: "Handlers", bundle: .module)
    }

    static func groupBody(_ count: Int) -> String {
        String(localized: "confirm.group.body", defaultValue: "\(count) workspaces and their terminals are closed.", table: "Handlers", bundle: .module)
    }

    static func closeTabGroupTitle(_ name: String) -> String {
        String(localized: "confirm.closeTabGroup.title", defaultValue: "Close the tab group “\(name)”?", table: "Handlers", bundle: .module)
    }

    static func tabGroupBody(_ count: Int) -> String {
        String(localized: "confirm.tabGroup.body", defaultValue: "\(count) tabs are closed.", table: "Handlers", bundle: .module)
    }

    static var unnamedGroup: String {
        String(localized: "confirm.group.unnamed", defaultValue: "Untitled", table: "Handlers", bundle: .module)
    }

    /// A socket write of a user-only setting (`cmux settings set --confirm`).
    static func userOnlySettingTitle(_ key: String) -> String {
        String(format: String(localized: "confirm.userOnlySetting.title", defaultValue: "Change %@?", table: "Handlers", bundle: .module), key)
    }

    static func userOnlySettingBody(_ key: String, _ value: String) -> String {
        String(format: String(localized: "confirm.userOnlySetting.body",
                              defaultValue: "A command asks to set %1$@ to %2$@. Only you can change this setting, so cmux asks you first.",
                              table: "Handlers", bundle: .module), key, value)
    }

    static var userOnlySettingButton: String {
        String(localized: "confirm.userOnlySetting.button", defaultValue: "Change", table: "Handlers", bundle: .module)
    }
}
