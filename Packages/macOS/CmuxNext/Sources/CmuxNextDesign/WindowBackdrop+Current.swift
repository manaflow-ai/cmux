public import CmuxNextDesignTokens

public extension WindowBackdrop {
    /// The backdrop a pane or page decides its own painting from: `tokens` with the active
    /// scope's art selection (the app's outside a scope), so over art the panes stay clear glass
    /// and the art reads through the window's one tint.
    @MainActor static func current(_ tokens: ThemeTokens, reduceTransparency: Bool = false) -> WindowBackdrop {
        let scope = ThemeContext.activeScope ?? ThemeScope.app
        return WindowBackdrop(tokens, reduceTransparency: reduceTransparency, selection: ThemeContext.activeBackdropSelection,
                              tintOpacity: scope.backdropTintOpacity)
    }

    /// The tint the active scope's window shows under its surfaces (``tintOpacity``, the picture's
    /// tint over art), which a surface's own opacity is measured against
    /// (``SurfaceBackgrounds/fill(for:tokens:windowTint:)``).
    @MainActor static func currentTint(_ tokens: ThemeTokens) -> Double {
        current(tokens).tintOpacity
    }
}

public extension ThemeScope {
    /// The window opacity this scope's window paints, where Settings' unset Opacity slider rests:
    /// the theme's opacity, or over a background picture the tint the window lays over it (an
    /// unset slider sat at Ghostty's 100% while the window showed a lighter tint).
    var shownWindowOpacity: Double {
        _ = store.backdropRevision.value // Observed: re-read when the picture changes.
        guard backdropSelection != nil else { return input.backgroundOpacity }
        let backdrop = WindowBackdrop(tokens, art: backdropArt, selection: backdropSelection,
                                      tuning: appearanceTuning, tintOpacity: backdropTintOpacity)
        return backdrop.isOpaque ? input.backgroundOpacity : backdrop.tintOpacity
    }
}
