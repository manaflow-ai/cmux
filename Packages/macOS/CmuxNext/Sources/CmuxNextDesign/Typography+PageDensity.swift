public import CoreGraphics

public extension Typography {
    /// The size scale a page's density-following chrome draws at (`--cmux-density-scale`: the composer,
    /// New Tab, the model menu): the density's chrome row (``Metrics/densityRowHeight``: a tab, the omnibar and a
    /// sidebar row) over Default's, so those controls grow and shrink with the tabs (Lucas 2026-11-13: the composer
    /// should change size proportionally with the 20, 30 and 34 pt rows). Unlike ``pageScale`` it goes below 1, so
    /// Compact and Ultra-compact draw them smaller (Lawrence 2026-11-11: "if I change densities, this should change
    /// the size of everything on this page").
    static var pageDensityScale: CGFloat { Metrics.densityRowHeight / Metrics.defaultDensityRowHeight }
    /// The text scale beside ``pageDensityScale`` (`--cmux-density-text-scale`): the chrome body size
    /// (Text Size, else the density's) over Default's 13 pt, in both directions.
    static var pageDensityTextScale: CGFloat {
        let interfaceScale = DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1
        let body = DesignSettings.shared.overrides[.chromeFontSize] ?? Metrics.tokens.bodySize
        return body / DensityPreset.cozy.tokens.bodySize * interfaceScale
    }
}
