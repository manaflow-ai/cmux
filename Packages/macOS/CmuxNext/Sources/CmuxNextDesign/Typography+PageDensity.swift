public import CoreGraphics

public extension Typography {
    /// The size scale a page's density-following chrome draws at (`--cmux-density-scale`: the composer,
    /// New Tab, the model menu): the density's control height over Default's, so those controls grow and
    /// shrink with the native ones. Unlike ``pageScale`` it goes below 1, so Compact and Ultra-compact
    /// draw them smaller (Lawrence 2026-11-11: "if I change densities, this should change the size of
    /// everything on this page").
    static var pageDensityScale: CGFloat {
        let control = MetricTunables.controlHeight
        let drawn = DensityPreset.cozy.tokens.resolve(compact: control.compact, comfortable: control.comfortable)
        return Metrics.controlHeight / drawn
    }
    /// The text scale beside ``pageDensityScale`` (`--cmux-density-text-scale`): the chrome body size
    /// (Text Size, else the density's) over Default's 13 pt, in both directions.
    static var pageDensityTextScale: CGFloat {
        let interfaceScale = DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1
        let body = DesignSettings.shared.overrides[.chromeFontSize] ?? Metrics.tokens.bodySize
        return body / DensityPreset.cozy.tokens.bodySize * interfaceScale
    }
}
