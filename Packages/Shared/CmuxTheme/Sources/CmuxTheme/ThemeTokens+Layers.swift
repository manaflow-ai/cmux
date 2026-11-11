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
    ///
    /// The content's surface reads as the selection only where it stands out of the chrome around it:
    /// no shade (a chrome that shares the content's surface), or a shade too faint to see over a very
    /// dark content (black over Builtin Dark's #000000), would hide it, so it is nil there too
    /// (``selectedOnChrome(_:chromeShade:)``).
    public func selectedSurface(panesPaint: Bool, chromeShade: Double) -> ThemeRGB? {
        panesPaint ? Self.selectedOnChrome(selectedSurface.withAlpha(1), chromeShade: chromeShade) : nil
    }

    /// The lowest WCAG contrast between a selected item in the content's surface and the chrome it
    /// sits on (black at the chrome's shade over that surface) for the item to read as selected. The
    /// default shades clear it on every built-in theme but the near-black ones: white under the light
    /// shade (0.045) is 1.10, #1E1E1E under the dark one (0.28) 1.09, #000000 1.00.
    public static let minimumSelectedContrast = 1.04

    /// `content`, opaque, when it reads as a selection on its chrome (black at `chromeShade` over it,
    /// ``chromeSurface(shade:)``): opaque itself, and at least ``minimumSelectedContrast`` from that
    /// chrome. nil otherwise: the caller keeps `selectionFill`, which always shows.
    public static func selectedOnChrome(_ content: ThemeRGB, chromeShade: Double) -> ThemeRGB? {
        guard content.alpha >= 1 else { return nil }
        let chrome = ThemeRGB.black.withAlpha(min(max(chromeShade, 0), 1)).composited(over: content)
        return content.contrast(with: chrome) >= minimumSelectedContrast ? content : nil
    }
}
