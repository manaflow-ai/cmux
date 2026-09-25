import Foundation

/// Settings under the dotted-id prefix `rightSidebar.*`.
public struct RightSidebarCatalogSection: SettingCatalogSection {
    /// Whether the persistent right-sidebar toggle is present in the titlebar.
    public let showTitlebarToggle = DefaultsKey<Bool>(
        id: "rightSidebar.showTitlebarToggle",
        defaultValue: RightSidebarChromeSettings.defaultShowTitlebarToggle,
        userDefaultsKey: RightSidebarChromeSettings.showTitlebarToggleKey
    )

    /// Whether the right-sidebar mode bar offers Open as Pane.
    public let showOpenAsPaneButton = DefaultsKey<Bool>(
        id: "rightSidebar.showOpenAsPaneButton",
        defaultValue: RightSidebarChromeSettings.defaultShowOpenAsPaneButton,
        userDefaultsKey: RightSidebarChromeSettings.showOpenAsPaneButtonKey
    )

    /// Creates the right-sidebar settings section.
    public init() {}
}
