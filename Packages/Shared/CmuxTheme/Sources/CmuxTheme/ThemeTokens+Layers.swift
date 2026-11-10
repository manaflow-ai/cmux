import Foundation

/// The foreground and background layers (design/selected-is-foreground.md).
///
/// Leo, 2026-11-10: "The selected tab should be white as well ... what does your selected one look
/// like? Well, it looks like the one that's foregrounded." Two layers make every window: the
/// content (the terminal, a page, a chat), which is the foreground, and the chrome around it
/// (sidebar, titlebar, tab strips), which is the background. A selected item is part of the
/// foreground, so it is drawn in the content's own surface: white in a light theme, the content's
/// black in a dark one, the content's tint over an image. An item at rest sits on the chrome.
/// Nothing selects with a gray pill of its own any more.
extension ThemeTokens {
    /// The foreground layer: what content draws behind itself (the terminal's background with its
    /// opacity). The surface of every selected item.
    public var contentSurface: ThemeRGB { contentBackground }

    /// The selected state: the content surface, always (`check-selected-surface.py`).
    public var selectedSurface: ThemeRGB { contentSurface }

    /// The background layer: the chrome's shade, black at `shade` over the content surface
    /// (`Metrics.mainPaneChromeShade`), made opaque. What a page that draws chrome and content
    /// side by side paints behind its chrome (`--cmux-chrome-surface`).
    public func chromeSurface(shade: Double) -> ThemeRGB {
        ThemeRGB.black.withAlpha(min(max(shade, 0), 1)).composited(over: contentSurface.withAlpha(1))
    }

    /// The selected surface laid over the chrome's shade (black at `shade`) so that it shows what
    /// the content surface shows over the window's backdrop: the same color in an opaque window,
    /// and in a see-through one (a translucent theme, an image background) the same mix of tint
    /// and backdrop, so a selected tab and the content it opens read as one surface.
    ///
    /// Over a backdrop `B`, content of alpha `a` shows `a·S + (1-a)·B`; a fill of alpha `f` over
    /// the shade shows `f·F + (1-f)(1-k)·B`. Equal when `f = 1 - (1-a)/(1-k)` and `F = a·S/f`.
    /// A surface more see-through than the shade is dark (`a <= k`) cannot be matched without
    /// knowing the backdrop: nil, and the caller keeps a fill that still shows (a folder tab cuts the
    /// shade away instead, `ChromeShadeHoles`, and needs no match).
    public func selectedSurface(overChromeShade shade: Double) -> ThemeRGB? {
        Self.surface(selectedSurface, overChromeShade: shade)
    }

    /// ``selectedSurface(overChromeShade:)`` for any content surface (a page's own background).
    public static func surface(_ surface: ThemeRGB, overChromeShade shade: Double) -> ThemeRGB? {
        let a = min(max(surface.alpha, 0), 1), k = min(max(shade, 0), 1)
        guard a < 1, k > 0 else { return surface }
        guard k < 1 else { return nil }
        let fill = 1 - (1 - a) / (1 - k)
        guard fill > 0 else { return nil }
        let scale = a / fill
        return ThemeRGB(red: min(surface.red * scale, 1), green: min(surface.green * scale, 1),
                        blue: min(surface.blue * scale, 1), alpha: fill)
    }
}
