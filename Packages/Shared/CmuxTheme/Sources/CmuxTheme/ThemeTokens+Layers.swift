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

    /// The selected surface for an item drawn over the chrome's shade, such as a sidebar row: the
    /// content surface, opaque, when panes paint it (an opaque window), which covers the shade exactly
    /// as the content does. In a see-through window the content is the window's one tint over the
    /// backdrop and the shade lies on that tint, so a fill over the shade can never show what the
    /// content shows for an unknown backdrop (it would add the tint twice): nil, and the caller keeps
    /// a fill that still shows. A folder tab cuts the shade away instead and needs no fill.
    public func selectedSurface(panesPaint: Bool) -> ThemeRGB? {
        panesPaint ? selectedSurface.withAlpha(1) : nil
    }
}
