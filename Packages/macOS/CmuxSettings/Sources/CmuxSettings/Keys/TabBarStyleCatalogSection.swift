import Foundation

/// Top-level surface (pane) tab bar style settings (issue #7458).
///
/// These keys make the horizontal surface tab bar directly themeable on a
/// per-selection-state basis — background, label, divider, active-indicator
/// color, and title typography — independently of the sidebar workspace list.
/// Like ``PaneChromeCatalogSection`` they keep their `cmux.json` paths at the
/// root, because they customize the workspace tab chrome itself rather than a
/// nested app section, and they mirror the existing top-level `paneBorderColor`
/// precedent.
///
/// Every key defaults to empty, meaning "no override": Bonsplit keeps its
/// derived styling for that attribute, so the feature is fully backward
/// compatible.
public struct TabBarStyleCatalogSection: SettingCatalogSection {
    /// Background color for the selected tab (6-digit `#RRGGBB`).
    public let activeBackground = DefaultsKey<String>(
        id: "tabBarActiveBackground",
        defaultValue: "",
        userDefaultsKey: "tabBarActiveBackground"
    )

    /// Label color for the selected tab (6-digit `#RRGGBB`).
    public let activeForeground = DefaultsKey<String>(
        id: "tabBarActiveForeground",
        defaultValue: "",
        userDefaultsKey: "tabBarActiveForeground"
    )

    /// Background color for unselected tabs (6-digit `#RRGGBB`).
    public let inactiveBackground = DefaultsKey<String>(
        id: "tabBarInactiveBackground",
        defaultValue: "",
        userDefaultsKey: "tabBarInactiveBackground"
    )

    /// Label color for unselected tabs (6-digit `#RRGGBB`).
    public let inactiveForeground = DefaultsKey<String>(
        id: "tabBarInactiveForeground",
        defaultValue: "",
        userDefaultsKey: "tabBarInactiveForeground"
    )

    /// Background color for a hovered, unselected tab (6-digit `#RRGGBB`).
    public let hoverBackground = DefaultsKey<String>(
        id: "tabBarHoverBackground",
        defaultValue: "",
        userDefaultsKey: "tabBarHoverBackground"
    )

    /// Color for the thin dividers between tabs. The literal `none` hides them.
    public let dividerColor = DefaultsKey<String>(
        id: "tabBarDividerColor",
        defaultValue: "",
        userDefaultsKey: "tabBarDividerColor"
    )

    /// Color for the accent indicator on the selected tab (6-digit
    /// `#RRGGBB`). Replaces the macOS system-accent indicator.
    public let activeIndicatorColor = DefaultsKey<String>(
        id: "tabBarActiveIndicatorColor",
        defaultValue: "",
        userDefaultsKey: "tabBarActiveIndicatorColor"
    )

    /// Which edge carries the accent indicator: `top`, `bottom`, or `none`.
    public let activeIndicatorEdge = DefaultsKey<String>(
        id: "tabBarActiveIndicatorEdge",
        defaultValue: "",
        userDefaultsKey: "tabBarActiveIndicatorEdge"
    )

    /// Font family for tab title labels. Empty keeps the system font.
    public let fontFamily = DefaultsKey<String>(
        id: "tabBarFontFamily",
        defaultValue: "",
        userDefaultsKey: "tabBarFontFamily"
    )

    /// Font weight for tab title labels (`ultraLight`…`black`).
    public let fontWeight = DefaultsKey<String>(
        id: "tabBarFontWeight",
        defaultValue: "",
        userDefaultsKey: "tabBarFontWeight"
    )

    /// Creates the tab bar style settings section with its default keys.
    public init() {}
}
