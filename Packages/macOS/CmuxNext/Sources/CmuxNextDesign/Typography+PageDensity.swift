public import CoreGraphics

public extension Typography {
    /// The size scale a page's density-following chrome draws at (`--cmux-density-scale`: the composer,
    /// New Tab, the model menu): the density's chrome row (``Metrics/densityRowHeight``: a tab, the omnibar and a
    /// sidebar row) over Default's, so those controls grow and shrink with the tabs (Lucas 2026-11-13: the composer
    /// should change size proportionally with the 20, 30 and 34 pt rows). Unlike ``pageScale`` it goes below 1, so
    /// Compact and Ultra-compact draw them smaller (Lawrence 2026-11-11: "if I change densities, this should change
    /// the size of everything on this page").
    static var pageDensityScale: CGFloat { Metrics.tokens.uniformScale.map { Metrics.scale($0) } ?? (Metrics.densityRowHeight / Metrics.defaultDensityRowHeight) }
    /// The sidebar row's title size over Default's (`--cmux-row-text-scale`): a page's rows (New Tab's suggestions)
    /// draw their text this much larger or smaller than at Default, so they match the density's sidebar rows and tabs
    /// as Default's do (Lucas 2026-11-15: "they need to match the rest of the density").
    /// It carries the person's text scale (``userScale``), as the sidebar's own titles do, so Text Size grows the rows too.
    static var pageRowTextScale: CGFloat {
        sidebarTitleSize(Metrics.tokens) / max(1, sidebarTitleSize(DensityPreset.cozy.tokens)) * userScale
    }
    /// The density's icon box over Default's (`--cmux-row-icon-scale`): a page's row glyphs grow with the sidebar's
    /// and the tabs' icons.
    static var pageRowIconScale: CGFloat {
        Metrics.tabIconSize / max(1, CGFloat(DensityPreset.cozy.tokens.tokens["tabIconSize"] ?? 16))
    }
    /// The text scale beside ``pageDensityScale`` (`--cmux-density-text-scale`): the chrome body size
    /// (Text Size, else the density's) over Default's 13 pt, in both directions.
    static var pageDensityTextScale: CGFloat {
        let interfaceScale = DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1
        let body = DesignSettings.shared.overrides[.chromeFontSize] ?? Metrics.tokens.bodySize
        return body / DensityPreset.cozy.tokens.bodySize * interfaceScale
    }
}
