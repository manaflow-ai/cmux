public import CoreGraphics
public import CmuxNextDesign

/// The omnibar's sizes at one density (https://github.com/manaflow-ai/cmux/issues/28734): the bar,
/// its text, the toolbar buttons beside it and their icons. The bar and the buttons are the window's
/// one chrome row, a sidebar workspace row and a tab pill tall (`Metrics.chromeRowHeight`; Lawrence
/// 2026-11-09): 24 pt at Standard (the `compact` preset, level 0, the default) and 32 at Comfortable,
/// with 14 and 15 pt text (`TypeScale.field` to `TypeScale.title`), 13 pt chip icons, 18 pt trailing
/// icons, and toolbar glyphs whose ink is a tab icon's side (14 and 16 pt). Other densities sit on the
/// same line by their level (`DensityTokens.resolve`), and the text fits the row: Ultra-compact's
/// 20 pt row draws 11 pt text. A custom density's `fontSize` scales the text with the rest of the
/// chrome.
///
/// `browser.omnibar.height` and `browser.omnibar.fontSize` (`OmnibarGlassAppearance`) override the
/// bar height and text size; unset, they follow density. The bar is never shorter than its text
/// needs (`minimumBarHeight`), so no override clips the URL, the page-info chip or a suggestion row.
/// Pure, so the rules are tested with fixed numbers.
public nonisolated struct OmnibarMetrics: Equatable, Sendable {
    /// The bar's height, and each suggestion row's.
    public var barHeight: CGFloat
    /// The URL text, page-info chip text and suggestion rows.
    public var fontSize: CGFloat
    /// The square toolbar buttons (back, forward, reload, extensions).
    public var buttonSize: CGFloat
    /// The page-info chip and suggestion row icons.
    public var iconPointSize: CGFloat
    /// The toolbar buttons' icons.
    public var toolbarIconSize: CGFloat
    /// The star and other trailing address-bar icons.
    public var trailingIconSize: CGFloat
    /// The Extensions puzzle's drawing side: a density's `omnibarExtensionsGlyphSize` (Compact's 27 pt draws 16 pt of
    /// ink), else `toolbarIconSize`; never past its button.
    public var extensionsIconSize: CGFloat
    /// The bookmark star's drawing side: a density's `omnibarStarGlyphSize` (Compact's 23.5 pt draws 13.5 pt of ink, Default's
    /// 28 pt 16), else `toolbarIconSize`. Its ink (`starInkRatio` of the side) stays inside its plate (`starPlateSize`);
    /// the side's clear margin may pass it.
    public var starIconSize: CGFloat
    /// The star's button and hover plate: Helium's, a square the bar's height less its edge inset on each side (24 pt on
    /// Compact's 28 pt bar; Lucas 2026-11-18: "match it 1:1"), or a density's `omnibarStarPlateSize` (Default's 28 pt,
    /// Compact's padding around its 16 pt star).
    public var starPlateSize: CGFloat
    /// The star's ink height over its drawing side: 27 rows at 2x on a 23.5 pt side.
    public static let starInkRatio: CGFloat = 13.5 / 23.5

    /// `browser.omnibar.height`'s allowed range in points (the settings row's range,
    /// `BrowserOmnibarSetting.heightRange`; `OmnibarDensityTests` keeps the two equal).
    public static let heightRange: ClosedRange<Double> = 20...56
    /// `browser.omnibar.fontSize`'s allowed range in points (`BrowserOmnibarSetting.fontSizeRange`).
    public static let fontSizeRange: ClosedRange<Double> = 10...24
    /// Space the bar keeps above and below its text line together: the page-info chip's 2 pt inset on
    /// each side, then 1 pt of the chip's own padding, so a 24 pt row holds 14 pt text.
    static let textClearance: CGFloat = 6

    /// The metrics at `tokens`, with the user's overrides (each clamped into its range).
    /// `textScale` is the caller's live Interface Size multiplier; pure callers keep reference sizes.
    /// - Parameters:
    ///   - rowHeight: The chrome row the bar and buttons take; nil uses the density's
    ///     (``DensityTokens/toolbarButtonSize``), without the sidebar's extra height.
    ///   - glyphSide: The toolbar glyphs' side; nil uses the density's (``DensityTokens/toolbarGlyphSize``).
    ///   - buttonSide: The toolbar buttons' side, even past the row's height; nil uses the density's `omnibarButtonSize`
    ///     (at most the row's height), else the row's height.
    public init(tokens: DensityTokens, height: Double? = nil, fontSize: Double? = nil, textScale: CGFloat = 1,
                rowHeight: CGFloat? = nil, glyphSide: CGFloat? = nil, buttonSide: CGFloat? = nil) {
        let row = rowHeight ?? tokens.toolbarButtonSize
        let requested = height.flatMap { $0.isFinite ? CGFloat(Self.clamp($0, Self.heightRange).rounded()) : nil } ?? row
        // A built-in density's text fits the bar's line (Ultra-compact's 20 pt row draws 11 pt text,
        // whole points), its own `fontSize` too, so the bar stays the tab's height (Lawrence 2026-11-11:
        // "omnibar height should be same as tabbar tab height"). A custom density's `fontSize` and
        // Interface Size are the user's: the bar grows for them instead (`minimumBarHeight`).
        // The URL text is the density's body text: 14 pt at Default and Comfortable, Helium's and Chrome's address
        // bar (Lawrence 2026-11-13: their font sizes; Lucas 2026-11-13: the ChatGPT app's 14 pt body).
        var levelFont = tokens.bodySize
        if tokens.fontSize == nil || tokens.isBuiltIn {
            levelFont = min(levelFont, max(CGFloat(Self.fontSizeRange.lowerBound), ((requested - Self.textClearance) / 1.25).rounded(.down)))
        }
        // A density's own URL text size (`omnibarFontSize`, Spacious's 20 pt; Lucas 2026-11-16), else its body text.
        let densityFont = (tokens.fontToken("omnibarFontSize") ?? levelFont) * textScale
        let font = fontSize.flatMap { $0.isFinite ? CGFloat(Self.clamp($0, Self.fontSizeRange).rounded()) : nil } ?? densityFont
        barHeight = max(requested, Self.minimumBarHeight(fontSize: font))
        self.fontSize = font
        // The side the caller gives (the chrome's: a tab's height, as the tab bar's ⋮ above the toolbar's; Lawrence
        // 2026-11-23), which the toolbar row grows to hold (`OmnibarStyle.rowContentHeight`); else a density's own button
        // side (Default's Compact 28 pt on its 34 pt bar), else the row's height (Helium's `kToolbarButtonHeight`).
        buttonSize = buttonSide ?? min(row, tokens.tokens["omnibarButtonSize"].map { CGFloat($0) } ?? row)
        // The chip is the bar less 2 pt on each side. Its glyph draws at `iconRowSize`, about 1.2
        // times this point size (13 -> 16 at Standard), and keeps 2 pt inside the chip, so a short
        // bar shrinks it (a suggestion row centers the glyph on the chip's center).
        // Default's omnibar is Compact's (`DensityPreset.omnibarScaleFactor`), so its level-based sizes are Compact's too.
        let levelTokens = tokens.isBuiltIn && tokens.id == DensityPreset.cozy.rawValue ? DensityPreset.compact.tokens : tokens
        iconPointSize = min(levelTokens.resolve(compact: 13, comfortable: 15), ((barHeight - 8) / 1.2).rounded(.down))
        toolbarIconSize = min(glyphSide ?? tokens.toolbarGlyphSize, buttonSize)
        // A density's `omnibarTrailingIconSize` (Helium's `kLocationBarTrailingIconSize` 18, Chrome's 20).
        trailingIconSize = min(tokens.tokens["omnibarTrailingIconSize"].map { CGFloat($0) } ?? tokens.resolve(compact: 18, comfortable: 20), barHeight - 6)
        extensionsIconSize = min(tokens.tokens["omnibarExtensionsGlyphSize"].map { CGFloat($0) } ?? toolbarIconSize, buttonSize)
        starPlateSize = min(barHeight, tokens.tokens["omnibarStarPlateSize"].map { CGFloat($0) }
            ?? max(0, barHeight - 2 * (tokens.tokens["omnibarEdgeInset"].map { CGFloat($0) } ?? 2)))
        starIconSize = min(tokens.tokens["omnibarStarGlyphSize"].map { CGFloat($0) } ?? toolbarIconSize,
                           starPlateSize / Self.starInkRatio)
    }

    /// The shortest bar that holds a line of `fontSize` text with `textClearance` around it. The
    /// system font's line is under 1.25 times its size, so this never cuts a glyph.
    public static func minimumBarHeight(fontSize: CGFloat) -> CGFloat {
        (fontSize * 1.25).rounded(.up) + textClearance
    }

    /// The metrics chrome draws now: the active density and cmux.json's overrides. Reading it in
    /// an Observation-tracked scope (`DensityBinding`) re-applies on a density or override change.
    @MainActor public static var current: OmnibarMetrics {
        let overrides = OmnibarGlassAppearance.current
        return OmnibarMetrics(tokens: Metrics.tokens, height: overrides.height, fontSize: overrides.fontSize,
                              textScale: Typography.userScale, rowHeight: Metrics.tokens.tokens["omnibarHeight"].map { Metrics.scale(CGFloat($0)) } ?? Metrics.tabHeight, glyphSide: Metrics.toolbarGlyphSize,
                              buttonSide: Metrics.tabBarControlSide)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
