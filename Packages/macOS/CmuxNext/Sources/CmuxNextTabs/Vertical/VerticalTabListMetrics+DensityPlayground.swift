public import CmuxNextDesign

public extension VerticalTabListMetrics {
    /// What a pane's vertical tab list and the tab strip draw for each Density Playground value a density does not
    /// set (``DensityTokenCatalog``), so a slider starts at the value on screen.
    nonisolated static let densityFallbacks: DensityTokenCatalog.Fallbacks = [
        "verticalTabRowHeight": { current.rowHeight },
        "verticalTabRowGap": { current.rowSpacing },
        "verticalTabPadding": { current.padding },
        "verticalTabIconSize": { current.iconSize },
        "verticalTabHeaderHeight": { current.headerHeight },
        "verticalTabIndent": { current.groupIndent },
        "verticalTabCornerRadius": { current.cornerRadius },
        "verticalTabTileSize": { current.tileSize },
        "verticalTabWidth": { VerticalTabTunables.expandedWidth.value },
        "tabIconTitleGap": { TabTunables.iconTitleSpacing.value },
    ]
}
