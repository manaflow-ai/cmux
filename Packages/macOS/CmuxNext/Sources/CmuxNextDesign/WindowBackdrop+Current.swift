
public extension WindowBackdrop {
    /// The backdrop a pane or page decides its own painting from: `tokens` with the active
    /// scope's art selection (the app's outside a scope), so over art the panes stay clear glass
    /// and the art reads through the window's one legible tint.
    @MainActor static func current(_ tokens: ThemeTokens, reduceTransparency: Bool = false) -> WindowBackdrop {
        WindowBackdrop(tokens, reduceTransparency: reduceTransparency, selection: ThemeContext.activeBackdropSelection)
    }
}

public extension ThemeScope {
    /// The window opacity this scope's window paints, where Settings' unset Opacity slider rests:
    /// the theme's opacity, or over a background picture the tint the picture and the legibility
    /// floor resolve (an unset slider sat at Ghostty's 100% while the window showed the work's 35%).
    var shownWindowOpacity: Double {
        guard let backdrop = shownArtBackdrop, !backdrop.isOpaque else { return input.backgroundOpacity }
        return backdrop.tintOpacity
    }

    /// The least window opacity this scope's window paints over its background picture (the
    /// legibility floor, ``WindowBackdrop/legibleTintOpacity``), where Settings' Opacity slider
    /// starts: below it the slider moved nothing. Nil without a picture or in an opaque window.
    var shownWindowOpacityFloor: Double? {
        guard let backdrop = shownArtBackdrop, !backdrop.isOpaque else { return nil }
        return backdrop.legibleTintOpacity
    }

    /// The backdrop this scope's window paints over its background picture; nil without one. One
    /// place, so the resting value and the floor always come from the same backdrop.
    private var shownArtBackdrop: WindowBackdrop? {
        guard backdropSelection != nil else { return nil }
        return WindowBackdrop(tokens, art: backdropArt, selection: backdropSelection,
                              tuning: appearanceTuning, tintOpacity: backdropTintOpacity)
    }
}
