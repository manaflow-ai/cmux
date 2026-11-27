import Foundation

/// Top-level cmux pane chrome settings.
///
/// These keys intentionally keep their `cmux.json` paths at the root because
/// they customize the workspace pane layout itself rather than a nested app
/// section.
public struct PaneChromeCatalogSection: SettingCatalogSection {
    /// Optional pane divider color for split workspaces.
    public let paneBorderColorHex = DefaultsKey<String>(
        id: "paneBorderColor",
        defaultValue: "",
        userDefaultsKey: "paneBorderColor"
    )

    /// Optional focused pane border color for split workspaces.
    public let activePaneBorderColorHex = DefaultsKey<String>(
        id: "activePaneBorderColor",
        defaultValue: "",
        userDefaultsKey: "activePaneBorderColor"
    )

    /// Creates the pane chrome settings section with its default keys.
    public init() {}
}
