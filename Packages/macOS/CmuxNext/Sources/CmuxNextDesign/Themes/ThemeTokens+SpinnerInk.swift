public import CmuxNextDesignTokens

extension ThemeTokens {
    /// The loading spinner's ink: ``textPrimary`` at 66% (a quieter mark than text), made more
    /// opaque only as far as it takes to reach ``minimumMarkContrast`` on the bare row and on the
    /// hovered, selected and pressed rows. A fixed 66% fell under 3:1 in low-contrast themes.
    public var spinnerInk: ThemeRGB {
        let row = windowBackground.withAlpha(1)
        let rows = [row, hoverFill.composited(over: row), selectionFill.composited(over: row), pressedFill.composited(over: row)]
        func reads(_ share: Double) -> Bool {
            let ink = textPrimary.withAlpha(textPrimary.alpha * share)
            return rows.allSatisfy { ink.composited(over: $0).contrast(with: $0) >= ThemeTokens.minimumMarkContrast }
        }
        var share = 0.66
        while share < 1, !reads(share) { share = min(1, share + 0.02) }
        return textPrimary.withAlpha(textPrimary.alpha * share)
    }
}
