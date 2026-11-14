public import AppKit

extension DensityTokens {
    /// A browser toolbar button's side: Helium's 28 pt at Standard (`kToolbarButtonHeight`), Chrome's 34
    /// at Comfortable. The browser's `OmnibarMetrics` and the pane's trailing control column
    /// (``Metrics/paneTrailingControlCenter``) both read it, so the two ⋮ buttons stay on one column.
    public var toolbarButtonSize: CGFloat { resolve(compact: 28, comfortable: 34) }

    /// The side every browser toolbar glyph draws at (Chrome's `kToolbarButtonIconSize`: 20 pt at
    /// Standard, 22 at Comfortable): back, forward, reload, the bookmark star, the Extensions puzzle
    /// and the pinned buttons. The pack fits each of those glyphs' ink to the back arrow's keyline
    /// (`design/icons/chromium/manifest.json` `fit`), so at this side every one has the same ink box,
    /// 0.6 of the side (12 pt at Standard), centered (Leo 2026-11-07: "the same sizing and the same,
    /// like, ratios and justifications").
    public var toolbarGlyphSize: CGFloat { resolve(compact: 20, comfortable: 22) }
}

extension Metrics {
    /// ``DensityTokens/toolbarGlyphSize`` at the active density.
    public static var toolbarGlyphSize: CGFloat { tokens.toolbarGlyphSize }

    /// The point size of the SF Symbols on the window's top controls: the toolbar band (sidebar
    /// toggle, Back, Forward), the pane tab bar's buttons and the sidebar's + menu. One size per
    /// density, ``smallIconSize``, so their ink (about 10 pt at Compact) matches the browser
    /// toolbar's.
    public static var toolbarSymbolPointSize: CGFloat { smallIconSize }

    /// The one SF Symbol weight of those controls: regular, the weight whose stroke matches the
    /// pack's line glyphs at these sizes.
    public static let toolbarSymbolWeight: NSFont.Weight = .regular
}
