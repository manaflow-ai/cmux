import Foundation

extension ThemeTokens {
    /// A lit (on, chosen, done) control's glyph or label, beside the same controls at rest in
    /// `textSecondary`: the accent, lifted toward the primary text just far enough to contrast with
    /// the window at least as much as the rest ink, so the theme's hue stays (Clay Orange's orange)
    /// and a lit control is never less visible than at rest. A theme with no accent lights in the
    /// primary text (`accent`), not `focusRing`'s 40% of it. Opaque.
    public var litGlyph: ThemeRGB {
        let surface = windowBackground.withAlpha(1)
        let lit = accent.composited(over: surface), primary = textPrimary.composited(over: surface)
        let floor = textSecondary.composited(over: surface).contrast(with: surface)
        if lit.contrast(with: surface) >= floor { return lit }
        // The least lift that reaches the floor; a primary text fainter than the floor is still the brightest ink.
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if lit.mixed(toward: primary, mid).contrast(with: surface) >= floor { high = mid } else { low = mid }
        }
        return lit.mixed(toward: primary, high)
    }
}
