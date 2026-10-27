public import CmuxTheme
public import CmuxNextDesignTokens

/// The resolver each surface's owner paints from (``SurfaceBackgrounds``): it reads the window's
/// tint from ``WindowBackdrop``, so it lives with it here.
nonisolated extension SurfaceBackgrounds {
    /// What `kind`'s owner paints over the window's backdrop, or nil when
    /// the surface has no override.
    ///
    /// - Parameter kind: The surface.
    /// - Parameter tokens: The theme tokens of the surface's scope (its
    ///   background color, `background-opacity` and blur).
    /// - Parameter windowTint: The tint the window shows under the surface
    ///   (``WindowBackdrop/tintOpacity``); over a background picture that is
    ///   the picture's tint, not `background-opacity`. nil reads the tokens'
    ///   own (no picture).
    public func fill(for kind: SurfaceKind, tokens: ThemeTokens, windowTint: Double? = nil) -> ThemeRGB? {
        guard let override = overrides[kind], !override.isEmpty else { return nil }
        let window = windowTint ?? WindowBackdrop(tokens).tintOpacity
        if let color = override.color {
            return color.withAlpha(color.alpha * (override.opacity ?? window))
        }
        let target = override.opacity ?? window
        // Over the tint (alpha `window`), alpha x of the same color covers
        // window + x * (1 - window) = target.
        let alpha = window >= 1 || target <= window ? 0 : (target - window) / (1 - window)
        return tokens.surfaceBackground.withAlpha(alpha)
    }

    /// `fill(for:tokens:)` laid over an opaque `base`, for owners that
    /// must paint an opaque color (a docked column hides what scrolls under
    /// it); `base` itself without an override.
    public func opaqueFill(for kind: SurfaceKind, tokens: ThemeTokens, base: ThemeRGB, windowTint: Double? = nil) -> ThemeRGB {
        guard let fill = fill(for: kind, tokens: tokens, windowTint: windowTint) else { return base }
        return fill.composited(over: base.withAlpha(1))
    }
}
