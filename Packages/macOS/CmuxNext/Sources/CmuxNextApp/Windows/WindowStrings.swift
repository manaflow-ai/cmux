import Foundation

/// Localized strings for windows. Keys live in Resources/Windows.xcstrings.
enum WindowStrings {
    /// Palette label of a window without a workspace name ("Window 2").
    static func windowNumber(_ number: Int) -> String {
        String(format: String(localized: "window.target.number", defaultValue: "Window %lld", table: "Windows", bundle: .module.inAppLanguage), number)
    }

    /// Titlebar badge of an incognito window.
    static var incognitoBadge: String {
        String(localized: "window.incognito.badge", defaultValue: "Incognito", table: "Windows", bundle: .module.inAppLanguage)
    }

    /// A pane whose tab draws in another window that shows the same space.
    static var tabShownElsewhere: String {
        String(localized: "window.tab.shownElsewhere", defaultValue: "This tab is shown in another window", table: "Windows", bundle: .module.inAppLanguage)
    }

    static var tabShowHere: String {
        String(localized: "window.tab.showHere", defaultValue: "Show Here", table: "Windows", bundle: .module.inAppLanguage)
    }

    static var incognitoHelp: String {
        String(localized: "window.incognito.help",
               defaultValue: "Incognito window. Its browser data is deleted when the last incognito window closes.",
               table: "Windows", bundle: .module.inAppLanguage)
    }
}
