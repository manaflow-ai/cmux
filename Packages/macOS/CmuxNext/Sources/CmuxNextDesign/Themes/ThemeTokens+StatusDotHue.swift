public import CmuxNextDesignTokens

extension ThemeTokens {
    /// `mark`'s hue in this theme: the system color of the theme's mode, its lightness moved
    /// (toward white on a dark row, black on a light one) only as far as it takes to reach
    /// ``minimumMarkContrast`` on the bare row and on the selected and pressed rows.
    /// - Parameter mark: The status mark.
    /// - Returns: The mark's opaque color.
    public func statusDot(_ mark: StatusDotHue) -> ThemeRGB {
        let row = windowBackground.withAlpha(1)
        let rows = [row, selectionFill.composited(over: row), pressedFill.composited(over: row)]
        return readableDot(mark.hue(isDark: isDark), over: rows, toward: row.relativeLuminance < 0.18 ? .white : .black)
    }
}

/// `color` mixed toward `pole` in 2% steps until it reaches 3:1 over every surface (or `pole`).
private func readableDot(_ color: ThemeRGB, over surfaces: [ThemeRGB], toward pole: ThemeRGB) -> ThemeRGB {
    func reads(_ ink: ThemeRGB) -> Bool { surfaces.allSatisfy { ink.contrast(with: $0) >= ThemeTokens.minimumMarkContrast } }
    var step = 0.0
    var candidate = color
    while step < 1, !reads(candidate) {
        step += 0.02
        candidate = color.mixed(toward: pole, step)
    }
    return candidate
}
