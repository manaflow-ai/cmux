public import CmuxNextDesign

public extension SidebarRowTuning {
    /// What the sidebar draws for each Density Playground value a density does not set (``DensityTokenCatalog``),
    /// so a slider starts at the value on screen.
    nonisolated static let densityFallbacks: DensityTokenCatalog.Fallbacks = [
        "sidebarRowGap": { rowGap.value },
        "sidebarRowInset": { outerInset.value },
        "sidebarContentInset": { contentInset.value },
        "sidebarCornerRadius": { cornerRadius.value },
        "sidebarIconColumn": { iconColumn.value },
        "sidebarIconGap": { glyphGap.value },
        "sidebarGroupIndent": { SidebarStyle.groupGutter },
        "sidebarHeadingSize": { headingSize.value },
        "sidebarSectionGap": { sectionGap.value },
        "sidebarBandGap": { bandGap.value },
        "sidebarStatusDot": { statusDot.value },
    ]
}
