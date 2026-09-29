import Foundation

/// Settings under the dotted-id prefix `rightSidebar.*`.
///
/// The `rightSidebar` object in `cmux.json` also holds legacy and
/// extension-owned configuration, so only the keys declared here are settings.
public struct RightSidebarCatalogSection: SettingCatalogSection {
    /// Where the persistent right-sidebar show/hide button lives.
    public let toggleButton = DefaultsKey<RightSidebarToggleButtonPlacement>(
        id: "rightSidebar.toggleButton",
        defaultValue: .titlebar,
        userDefaultsKey: "rightSidebar.toggleButton"
    )

    /// Creates the right-sidebar settings section.
    public init() {}
}
