import Foundation

/// Shared storage keys and defaults for right-sidebar chrome preferences.
public struct RightSidebarChromeSettings: Sendable {
    /// Creates the stateless right-sidebar chrome policy.
    public init() {}

    /// The `UserDefaults` key controlling the persistent titlebar toggle.
    public static let showTitlebarToggleKey = "rightSidebar.showTitlebarToggle"

    /// The `UserDefaults` key controlling the mode-bar Open as Pane button.
    public static let showOpenAsPaneButtonKey = "rightSidebar.showOpenAsPaneButton"

    /// The default visibility for the persistent titlebar toggle.
    public static let defaultShowTitlebarToggle = true

    /// The default visibility for the mode-bar Open as Pane button.
    public static let defaultShowOpenAsPaneButton = true
}
