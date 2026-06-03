import Foundation

/// Settings under the dotted-id prefix `ui.*` that are managed through the
/// Settings UI and persisted in the cmux JSON config file.
///
/// Only the keys cmux's Settings window reads and writes live here. Other
/// `ui.*` configuration (surface tab bar buttons, new-workspace placement) is
/// parsed directly from cmux.json by the app and is intentionally not part of
/// this catalog.
public struct UICatalogSection: SettingCatalogSection {
    /// Pane separator color as a `#RRGGBB` or `#RRGGBBAA` hex string.
    ///
    /// The empty default means "no explicit color": the divider falls back to
    /// the Ghostty `split-divider-color`, then to a theme-derived default.
    public let paneDividerColor = JSONKey<String>(
        id: "ui.paneDivider.color",
        defaultValue: ""
    )

    /// Pane separator thickness in points.
    ///
    /// Defaults to `1`, matching the app's `PaneDividerStyle.defaultThickness`
    /// (the legacy hairline). Raise it to make the separator more visible.
    public let paneDividerThickness = JSONKey<Double>(
        id: "ui.paneDivider.thickness",
        defaultValue: 1
    )

    /// Creates the section with its default key declarations.
    public init() {}
}
