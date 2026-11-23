public import CmuxNextDesign

public extension OmnibarMetrics {
    /// What the omnibar draws for each Density Playground value a density does not set (``DensityTokenCatalog``).
    nonisolated static let densityFallbacks: DensityTokenCatalog.Fallbacks = [
        "omnibarHeight": { current.barHeight },
        "omnibarFontSize": { current.fontSize },
        "omnibarCornerRadius": { OmnibarStyle.barCornerRadius },
        "omnibarIconSize": { OmnibarStyle.iconSide },
        "omnibarTextGap": { OmnibarStyle.textLeading },
        "omnibarButtonSpacing": { OmnibarStyle.buttonSpacing },
    ]
}
