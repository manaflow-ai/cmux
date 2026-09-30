import Foundation

/// Localized strings for windows. Keys live in Resources/Windows.xcstrings.
enum WindowStrings {
    static var emptyTitle: String {
        String(localized: "window.empty.title", defaultValue: "No workspaces in this window", table: "Windows", bundle: .module)
    }

    /// Palette label of a window without a workspace name ("Window 2").
    static func windowNumber(_ number: Int) -> String {
        String(format: String(localized: "window.target.number", defaultValue: "Window %lld", table: "Windows", bundle: .module), number)
    }

    static var newWorkspace: String {
        String(localized: "window.empty.newWorkspace", defaultValue: "New Workspace", table: "Windows", bundle: .module)
    }
}
