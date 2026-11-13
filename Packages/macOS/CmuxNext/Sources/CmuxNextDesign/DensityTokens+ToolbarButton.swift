public import AppKit

extension DensityTokens {
    /// A browser toolbar button's side: the sidebar's one-line row at this level, 24 pt at Standard and
    /// 32 at Comfortable, as tall as a tab pill (``Metrics/chromeRowHeight`` adds `sidebar.density`'s
    /// and `sidebar.textSize`'s extra height). The browser's `OmnibarMetrics` and the pane's trailing
    /// control column (``Metrics/paneTrailingControlCenter``) both read it, so the two ⋮ buttons stay
    /// on one column.
    /// A density's own `sidebarRowHeight` token sets it too (Compact's 20 pt), so metrics made without the live row agree
    /// with the chrome row.
    public var toolbarButtonSize: CGFloat { resolve(compact: 24, comfortable: 32, token: "sidebarRowHeight") }

    /// The share of a toolbar glyph's side its ink fills: the pack fits each toolbar glyph's ink to
    /// the back arrow's keyline, 14.4 of the 24 grid (`design/icons/chromium/manifest.json` `fit`),
    /// centered.
    public static let toolbarGlyphInkRatio: CGFloat = 0.6

    /// The side every browser toolbar glyph draws at: back, forward, reload, the bookmark star, the
    /// Extensions puzzle and the pinned buttons. Their ink box (``toolbarGlyphInkRatio`` of the side,
    /// centered, one box for every glyph: Leo 2026-11-07) is ``toolbarGlyphInk``, one point under the small icon
    /// size: 13 pt at Default, Helium's ink for Back, Forward and Reload (Lawrence 2026-11-13: the omnibar's
    /// arrows were bigger than Helium's).
    public var toolbarGlyphSize: CGFloat {
        Self.toolbarGlyphInk(smallIcon: resolveGlyph(compact: 12, comfortable: 14, token: "smallIconSize")) / Self.toolbarGlyphInkRatio
    }

    /// The toolbar glyphs' ink box for a small icon size: one point under it.
    public static func toolbarGlyphInk(smallIcon: CGFloat) -> CGFloat { max(1, smallIcon - 1) }
}

extension Metrics {
    /// ``DensityTokens/toolbarGlyphSize`` as chrome draws it: the side whose ink box is one point under the live
    /// ``smallIconSize`` (Interface Size and a set `smallIconSize` included).
    public static var toolbarGlyphSize: CGFloat {
        DensityTokens.toolbarGlyphInk(smallIcon: smallIconSize) / DensityTokens.toolbarGlyphInkRatio
    }

    /// The point size of the SF Symbols on the window's top controls: the toolbar band (sidebar
    /// toggle, Back, Forward), the pane tab bar's buttons and the sidebar's + menu. One size per
    /// density, ``smallIconSize``, so their ink (about 10 pt at Compact) matches the browser
    /// toolbar's.
    public static var toolbarSymbolPointSize: CGFloat { smallIconSize }

    /// The one SF Symbol weight of those controls: regular, the weight whose stroke matches the
    /// pack's line glyphs at these sizes.
    public static let toolbarSymbolWeight: NSFont.Weight = .regular
}
