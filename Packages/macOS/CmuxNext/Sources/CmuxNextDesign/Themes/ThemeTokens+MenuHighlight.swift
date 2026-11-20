public import CmuxNextDesignTokens

extension ThemeTokens {
    /// The share of ``accent`` in a highlighted row's wash on `ground` (``Palette/menuHighlight``):
    /// 20%, made lighter only as far as it takes ``textPrimary`` to keep ``minimumTextContrast`` on
    /// it. A fixed 20% took the label to 3.2:1 in low-contrast themes (Blue Dolphin, Batman).
    /// - Parameter ground: The opaque surface under the row (the card).
    /// - Returns: The wash's opacity, from 0.2 down to 0.
    public func menuHighlightShare(on ground: ThemeRGB) -> Double {
        let ink = textPrimary.composited(over: ground)
        var share = 0.2
        while share > 0, ink.contrast(with: accent.withAlpha(share).composited(over: ground)) < ThemeTokens.minimumTextContrast {
            share = max(0, share - 0.01)
        }
        return share
    }
}
