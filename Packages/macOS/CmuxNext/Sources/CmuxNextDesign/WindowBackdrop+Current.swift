
public extension WindowBackdrop {
    /// The backdrop a pane or page decides its own painting from: `tokens` with the active
    /// scope's art selection (the app's outside a scope), so over art the panes stay clear glass
    /// and the art reads through the window's one legible tint.
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
    /// the theme's opacity, or over a background picture the tint the picture and the legibility
    /// floor resolve (an unset slider sat at Ghostty's 100% while the window showed the work's 35%).
    var shownWindowOpacity: Double {
        guard backdropSelection != nil else { return input.backgroundOpacity }
        let backdrop = WindowBackdrop(tokens, art: backdropArt, selection: backdropSelection,
                                      tuning: appearanceTuning, tintOpacity: backdropTintOpacity)
        return backdrop.isOpaque ? input.backgroundOpacity : backdrop.tintOpacity
    }

    /// The least window opacity this scope's window can show, where Settings' Opacity slider
    /// starts: over a background picture the legibility floor (a lower value paints the same
    /// tint, so the slider's low end moved nothing); nil without a picture (0 works).
    var windowOpacityFloor: Double? {
        guard backdropSelection != nil else { return nil }
        let backdrop = WindowBackdrop(tokens, art: backdropArt, selection: backdropSelection,
                                      tuning: appearanceTuning, tintOpacity: backdropTintOpacity)
        return backdrop.isOpaque || backdrop.legibleTintOpacity <= 0 ? nil : backdrop.legibleTintOpacity
    }
}
