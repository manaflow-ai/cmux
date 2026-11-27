import Foundation

/// Settings under the dotted-id prefix `workspaceColors.*`.
public struct WorkspaceColorsCatalogSection: SettingCatalogSection {
    public let indicatorStyle = DefaultsKey<WorkspaceIndicatorStyle>(
        id: "workspaceColors.indicatorStyle",
        defaultValue: .leftRail,
        userDefaultsKey: "sidebarActiveTabIndicatorStyle"
    )

    public let selectionColorHex = DefaultsKey<String>(
        id: "workspaceColors.selectionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarSelectionColorHex"
    )

    /// Opt-in faint accent tint with a hairline edge for the selected
    /// workspace, in place of the solid fill (manaflow-ai/cmux#14890).
    public let subtleSelection = DefaultsKey<Bool>(
        id: "workspaceColors.subtleSelection",
        defaultValue: false,
        userDefaultsKey: "sidebarSubtleSelection"
    )

    /// Lightens workspace colors in dark mode so the palette stays readable on
    /// dark sidebars. Off shows the chosen color as-is (manaflow-ai/cmux#17128).
    public let brightenInDarkMode = DefaultsKey<Bool>(
        id: "workspaceColors.brightenInDarkMode",
        defaultValue: true,
        userDefaultsKey: "workspaceColorsBrightenInDarkMode"
    )

    /// Opacity of a workspace color filling a row that is not selected, with
    /// the Solid Fill indicator. Multi-selected rows use half of it
    /// (manaflow-ai/cmux#21232).
    public let unselectedFillOpacity = DefaultsKey<Double>(
        id: "workspaceColors.unselectedFillOpacity",
        defaultValue: 0.7,
        userDefaultsKey: "workspaceColorsUnselectedFillOpacity"
    )

    public let notificationBadgeColorHex = DefaultsKey<String>(
        id: "workspaceColors.notificationBadgeColor",
        defaultValue: "",
        userDefaultsKey: "sidebarNotificationBadgeColorHex"
    )

    public let palette = DefaultsKey<[String: String]>(
        id: "workspaceColors.colors",
        defaultValue: [:],
        userDefaultsKey: "workspaceTabColor.colors"
    )

    public let paletteOverrides = JSONKey<[String: String]>(
        id: "workspaceColors.paletteOverrides",
        defaultValue: [:]
    )

    public let customColors = JSONKey<[String]>(
        id: "workspaceColors.customColors",
        defaultValue: []
    )

    public init() {}
}
