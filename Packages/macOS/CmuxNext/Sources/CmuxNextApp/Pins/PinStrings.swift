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
    static var pinGroup: String { String(localized: "pins.pinGroup", defaultValue: "Pin Group", table: "Handlers", bundle: .module) }
    static var unpinGroup: String { String(localized: "pins.unpinGroup", defaultValue: "Unpin Group", table: "Handlers", bundle: .module) }
    static var addToTop: String { String(localized: "pins.addToTop", defaultValue: "Add to Top", table: "Handlers", bundle: .module) }
    static var removeFromTop: String {
        String(localized: "pins.removeFromTop", defaultValue: "Remove from Top", table: "Handlers", bundle: .module)
    }
    // The undo toast of each pin change (RECOVERABLE-BY-DEFAULT).
    static var tabPinned: String { String(localized: "pins.toast.tabPinned", defaultValue: "Tab pinned", table: "Handlers", bundle: .module) }
    static var tabUnpinned: String { String(localized: "pins.toast.tabUnpinned", defaultValue: "Tab unpinned", table: "Handlers", bundle: .module) }
    static var workspacePinned: String {
        String(localized: "pins.toast.workspacePinned", defaultValue: "Workspace pinned", table: "Handlers", bundle: .module)
    }
    static var workspaceUnpinned: String {
        String(localized: "pins.toast.workspaceUnpinned", defaultValue: "Workspace unpinned", table: "Handlers", bundle: .module)
    }
    static var addedToTop: String { String(localized: "pins.toast.addedToTop", defaultValue: "Added to Top", table: "Handlers", bundle: .module) }
    static var removedFromTop: String {
        String(localized: "pins.toast.removedFromTop", defaultValue: "Removed from Top", table: "Handlers", bundle: .module)
    }

    /// The toast message for an undo step named `title` (the action's own title when it has none).
    static func done(_ title: String) -> String {
        [pinTab: tabPinned, unpinTab: tabUnpinned, pinWorkspace: workspacePinned, unpinWorkspace: workspaceUnpinned,
         addToTop: addedToTop, removeFromTop: removedFromTop][title] ?? title
    }

    /// The workspace's machine gives it no id other devices can name.
    static var workspaceCannotPin: String {
        String(localized: "pins.workspaceCannotPin", defaultValue: "This workspace cannot be pinned: its machine has no shared workspace ID.",
               table: "Handlers", bundle: .module)
    }
}
