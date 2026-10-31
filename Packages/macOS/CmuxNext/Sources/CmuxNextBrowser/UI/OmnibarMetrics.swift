public import CoreGraphics
public import CmuxNextDesign

/// The omnibar's sizes at one density (https://github.com/manaflow-ai/cmux/issues/28734): the bar,
/// its text, the toolbar buttons beside it and their icons. Standard (the `compact` preset, level 0,
/// the default) is today's Helium bar exactly: a 28 pt bar and buttons, 14 pt text, 13 pt chip
/// icons, 20 pt toolbar icons, 18 pt trailing icons. Comfortable (level 1) is Chrome's roomier bar:
/// 34 pt (`kToolbarButtonHeight`), 15 pt text (`TypeScale.field` to `TypeScale.title`). Other densities sit on the same line by their level
/// (`DensityTokens.resolve`), so Ultra-compact is tighter than today and Spacious roomier, and a
/// custom density's `fontSize` scales the text with the rest of the chrome.
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

    /// `browser.omnibar.height`'s allowed range in points (the settings row's range,
    /// `BrowserOmnibarSetting.heightRange`; `OmnibarDensityTests` keeps the two equal).
    public static let heightRange: ClosedRange<Double> = 20...56
    /// `browser.omnibar.fontSize`'s allowed range in points (`BrowserOmnibarSetting.fontSizeRange`).
    public static let fontSizeRange: ClosedRange<Double> = 10...24
    /// Space the bar keeps above and below its text line: the page-info chip's 2 pt inset on each
    /// side, then 2 pt of the chip's own padding.
    static let textClearance: CGFloat = 8

    /// The metrics at `tokens`, with the user's overrides (each clamped into its range).
    /// `textScale` is the caller's live Interface Size multiplier; pure callers keep reference sizes.
    public init(tokens: DensityTokens, height: Double? = nil, fontSize: Double? = nil, textScale: CGFloat = 1) {
        let densityFont = tokens.textSize(compact: TypeScale.Base.field, comfortable: TypeScale.Base.title) * textScale
        // Whole points: a fractional bar would sit off the pixel grid.
        let font = fontSize.flatMap { $0.isFinite ? CGFloat(Self.clamp($0, Self.fontSizeRange).rounded()) : nil } ?? densityFont
        let densityHeight = tokens.resolve(compact: 28, comfortable: 34)
        let requested = height.flatMap { $0.isFinite ? CGFloat(Self.clamp($0, Self.heightRange).rounded()) : nil } ?? densityHeight
        barHeight = max(requested, Self.minimumBarHeight(fontSize: font))
        self.fontSize = font
        buttonSize = tokens.resolve(compact: 28, comfortable: 34)
        // The chip is the bar less 2 pt on each side. Its glyph draws at `iconRowSize`, about 1.2
        // times this point size (13 -> 16 at Standard), and keeps 2 pt inside the chip, so a short
        // bar shrinks it (a suggestion row centers the glyph on the chip's center).
        iconPointSize = min(tokens.resolve(compact: 13, comfortable: 15), ((barHeight - 8) / 1.2).rounded(.down))
        toolbarIconSize = min(tokens.resolve(compact: 20, comfortable: 22), buttonSize - 4)
        trailingIconSize = min(tokens.resolve(compact: 18, comfortable: 20), barHeight - 6)
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
                              textScale: Typography.userScale)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
