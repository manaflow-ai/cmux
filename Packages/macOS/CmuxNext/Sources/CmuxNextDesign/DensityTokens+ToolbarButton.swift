public import AppKit

extension DensityTokens {
    /// A browser toolbar button's side: the sidebar's one-line row at this level, 24 pt at Standard and
    /// 32 at Comfortable, as tall as a tab pill (``Metrics/chromeRowHeight`` adds `sidebar.density`'s
    /// and `sidebar.textSize`'s extra height). The browser's `OmnibarMetrics` and the pane's trailing
    /// control column (``Metrics/paneTrailingControlCenter``) both read it, so the two ⋮ buttons stay
    /// on one column.
    public var toolbarButtonSize: CGFloat { resolve(compact: 24, comfortable: 32) }

    /// The share of a toolbar glyph's side its ink fills: the pack fits each toolbar glyph's ink to
    /// the back arrow's keyline, 14.4 of the 24 grid (`design/icons/chromium/manifest.json` `fit`),
    /// centered.
    public static let toolbarGlyphInkRatio: CGFloat = 0.6

    /// The side every browser toolbar glyph draws at: back, forward, reload, the bookmark star, the
    /// Extensions puzzle and the pinned buttons. Their ink box (``toolbarGlyphInkRatio`` of the side,
    /// centered, one box for every glyph: Leo 2026-11-07) is a tab icon's side, 14 pt at Standard and
    /// 16 at Comfortable, so the arrows read at the tabs' size (Lawrence 2026-11-09).
    public var toolbarGlyphSize: CGFloat {
        resolveGlyph(compact: 14, comfortable: 16, token: "iconSize") / Self.toolbarGlyphInkRatio
    }
}

extension Metrics {
    /// ``DensityTokens/toolbarGlyphSize`` as chrome draws it: the side whose ink box is the tab icon's
    /// live ``iconSize`` (Interface Size and a set `iconSize` included).
    public static var toolbarGlyphSize: CGFloat { iconSize / DensityTokens.toolbarGlyphInkRatio }

    /// The point size of the SF Symbols on the window's top controls: the toolbar band (sidebar
    /// toggle, Back, Forward), the pane tab bar's buttons and the sidebar's + menu. One size per
    /// density, ``smallIconSize``, so their ink (about 10 pt at Compact) matches the browser
    /// toolbar's.
    public static var toolbarSymbolPointSize: CGFloat { smallIconSize }

    /// The one SF Symbol weight of those controls: regular, the weight whose stroke matches the
    /// pack's line glyphs at these sizes.
    public static let toolbarSymbolWeight: NSFont.Weight = .regular
}
