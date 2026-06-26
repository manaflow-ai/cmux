import Foundation

/// Settings under the dotted-id prefix `workspaceColors.*`.
public struct WorkspaceColorsCatalogSection: SettingCatalogSection {
    /// Default colors applied when agent-state coloring is enabled.
    public static let defaultStateColors: [String: String] = [
        "running": "#A04000",
        "needsInput": "#1565C0",
    ]

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

    /// Whether sidebar workspace tabs use agent lifecycle state colors.
    public let stateColorsEnabled = DefaultsKey<Bool>(
        id: "workspaceColors.stateColorsEnabled",
        defaultValue: false,
        userDefaultsKey: "workspaceColors.stateColorsEnabled"
    )

    /// How state colors combine with existing manual workspace colors.
    public let stateColorMode = DefaultsKey<WorkspaceStateColorMode>(
        id: "workspaceColors.stateColorMode",
        defaultValue: .replace,
        userDefaultsKey: "workspaceColors.stateColorMode"
    )

    /// Hex color map keyed by `AgentHibernationLifecycleState` raw value.
    public let stateColors = DefaultsKey<[String: String]>(
        id: "workspaceColors.stateColors",
        defaultValue: Self.defaultStateColors,
        userDefaultsKey: "workspaceColors.stateColors"
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
