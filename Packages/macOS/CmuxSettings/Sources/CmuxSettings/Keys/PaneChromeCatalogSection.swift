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

    public let focusMarkerStyle = DefaultsKey<String>(
        id: "focusMarkerStyle",
        defaultValue: "edge",
        userDefaultsKey: "focusMarkerStyle"
    )

    public let focusMarkerColorHex = DefaultsKey<String>(
        id: "focusMarkerColor",
        defaultValue: "",
        userDefaultsKey: "focusMarkerColor"
    )

    public let focusMarkerThickness = DefaultsKey<Double>(
        id: "focusMarkerThickness",
        defaultValue: 2.0,
        userDefaultsKey: "focusMarkerThickness"
    )

    public let focusMarkerIntensity = DefaultsKey<Double>(
        id: "focusMarkerIntensity",
        defaultValue: 0.24,
        userDefaultsKey: "focusMarkerIntensity"
    )

    public let focusMarkerVisibility = DefaultsKey<String>(
        id: "focusMarkerVisibility",
        defaultValue: "persistent",
        userDefaultsKey: "focusMarkerVisibility"
    )

    /// Creates the pane chrome settings section with its default keys.
    public init() {}
}
