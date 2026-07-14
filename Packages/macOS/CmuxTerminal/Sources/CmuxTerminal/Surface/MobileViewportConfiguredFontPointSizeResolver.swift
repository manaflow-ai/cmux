nonisolated struct MobileViewportConfiguredFontPointSizeResolver {
    let surfaceConfigFontPointSize: Float?
    let runtimeConfigFontPointSize: () -> Float?
    let fallbackBaseFontPointSize: () -> Float
    let magnificationPercent: Int

    func resolve() -> Float {
        if let surfaceConfigFontPointSize,
           surfaceConfigFontPointSize.isFinite,
           surfaceConfigFontPointSize > 0 {
            return surfaceConfigFontPointSize
        }
        let runtimeConfigFontPointSize = runtimeConfigFontPointSize()
        if let runtimeConfigFontPointSize,
           runtimeConfigFontPointSize.isFinite,
           runtimeConfigFontPointSize > 0 {
            return runtimeConfigFontPointSize
        }
        return MobileViewportResetFontPointSize(
            surfaceConfigFontPointSize: nil,
            runtimeConfigFontPointSize: nil,
            fallbackBaseFontPointSize: fallbackBaseFontPointSize(),
            magnificationPercent: magnificationPercent
        ).resolve()
    }
}
