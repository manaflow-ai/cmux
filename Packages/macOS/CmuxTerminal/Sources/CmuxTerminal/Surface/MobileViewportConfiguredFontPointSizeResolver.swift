nonisolated struct MobileViewportConfiguredFontPointSizeResolver {
    let surfaceConfigFontPointSize: Float?
    let runtimeConfigFontPointSize: () -> Float?
    let fallbackBaseFontPointSize: () -> Float
    let magnificationPercent: Int

    func resolve() -> Float {
        MobileViewportResetFontPointSize(
            surfaceConfigFontPointSize: surfaceConfigFontPointSize,
            runtimeConfigFontPointSize: runtimeConfigFontPointSize(),
            fallbackBaseFontPointSize: fallbackBaseFontPointSize(),
            magnificationPercent: magnificationPercent
        ).resolve()
    }
}
