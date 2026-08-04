import Foundation

/// JSON-backed appearance overrides under `ui.surfaceTabBar.*`.
public struct SurfaceTabBarCatalogSection: SettingCatalogSection {
    public let activeTabBackground = JSONKey<String>(
        id: "ui.surfaceTabBar.activeTabBackground",
        defaultValue: ""
    )

    public let activeTabForeground = JSONKey<String>(
        id: "ui.surfaceTabBar.activeTabForeground",
        defaultValue: ""
    )

    public let inactiveTabBackground = JSONKey<String>(
        id: "ui.surfaceTabBar.inactiveTabBackground",
        defaultValue: ""
    )

    public let inactiveTabForeground = JSONKey<String>(
        id: "ui.surfaceTabBar.inactiveTabForeground",
        defaultValue: ""
    )

    public let tabDividerColor = JSONKey<String>(
        id: "ui.surfaceTabBar.tabDividerColor",
        defaultValue: ""
    )

    public let activeTabIndicatorColor = JSONKey<String>(
        id: "ui.surfaceTabBar.activeTabIndicatorColor",
        defaultValue: ""
    )

    public let activeTabIndicatorEdge = JSONKey<String>(
        id: "ui.surfaceTabBar.activeTabIndicatorEdge",
        defaultValue: ""
    )

    public init() {}
}
