import Foundation

/// Localized strings for windows. Keys live in Resources/Windows.xcstrings.
enum WindowStrings {
    /// Palette label of a window without a workspace name ("Window 2").
    static func windowNumber(_ number: Int) -> String {
        String(format: String(localized: "window.target.number", defaultValue: "Window %lld", table: "Windows", bundle: .module), number)
    }

    /// Titlebar badge of an incognito window.
    static var incognitoBadge: String {
        String(localized: "window.incognito.badge", defaultValue: "Incognito", table: "Windows", bundle: .module)
    }

    static var incognitoHelp: String {
        String(localized: "window.incognito.help",
               defaultValue: "Incognito window. Its browser data is deleted when the last incognito window closes.",
               table: "Windows", bundle: .module)
    }

    /// Window rail button tooltip: "New Browser Tab (⇧⌘L)".
    static func railToolTip(_ title: String, shortcut: String) -> String {
        String(localized: "window.rail.toolTip", defaultValue: "\(title) (\(shortcut))", table: "Windows", bundle: .module)
    }
}
