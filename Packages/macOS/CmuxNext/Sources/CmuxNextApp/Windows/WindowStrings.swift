import Foundation

/// Localized strings for windows. Keys live in Resources/Windows.xcstrings.
enum WindowStrings {
    /// Palette label of a window without a workspace name ("Window 2").
    static func windowNumber(_ number: Int) -> String {
        String(format: String(localized: "window.target.number", defaultValue: "Window %lld", table: "Windows", bundle: .module), number)
    }
}
