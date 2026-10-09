import Foundation

/// Undo toast messages of tab icon changes (Handlers.xcstrings).
enum TabIconStrings {
    static var undoSet: String { String(localized: "tabIcon.undo.set", defaultValue: "Tab Icon Set", table: "Handlers", bundle: .module) }
    static var undoRemove: String {
        String(localized: "tabIcon.undo.remove", defaultValue: "Tab Icon Removed", table: "Handlers", bundle: .module)
    }
}
