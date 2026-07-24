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

    /// Keyword → color rules that tint a workspace whose title contains the
    /// keyword. Values are palette names or `#RRGGBB` hexes; a color set
    /// explicitly on a workspace always wins over a rule.
    public let autoColorRules = DefaultsKey<[String: String]>(
        id: "workspaceColors.autoColorRules",
        defaultValue: [:],
        userDefaultsKey: "workspaceTabColor.autoColorRules"
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
