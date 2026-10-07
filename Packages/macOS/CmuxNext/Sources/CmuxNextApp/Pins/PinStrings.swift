import Foundation

/// Pin and unpin titles: context menu titles of the pin toggles and undo
/// action names (Handlers.xcstrings, en and ja).
enum PinStrings {
    static var pinTab: String { String(localized: "pins.pinTab", defaultValue: "Pin Tab", table: "Handlers", bundle: .module) }
    static var unpinTab: String { String(localized: "pins.unpinTab", defaultValue: "Unpin Tab", table: "Handlers", bundle: .module) }
    static var pinWorkspace: String {
        String(localized: "pins.pinWorkspace", defaultValue: "Pin Workspace", table: "Handlers", bundle: .module)
    }
    static var unpinWorkspace: String {
        String(localized: "pins.unpinWorkspace", defaultValue: "Unpin Workspace", table: "Handlers", bundle: .module)
    }
    static var addToTop: String { String(localized: "pins.addToTop", defaultValue: "Add to Top", table: "Handlers", bundle: .module) }
    static var removeFromTop: String {
        String(localized: "pins.removeFromTop", defaultValue: "Remove from Top", table: "Handlers", bundle: .module)
    }
    /// The workspace's machine gives it no id other devices can name.
    static var workspaceCannotPin: String {
        String(localized: "pins.workspaceCannotPin", defaultValue: "This workspace cannot be pinned: its machine has no shared workspace ID.",
               table: "Handlers", bundle: .module)
    }
}
