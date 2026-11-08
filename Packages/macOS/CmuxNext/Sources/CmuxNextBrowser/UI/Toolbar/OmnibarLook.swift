public import CoreGraphics
public import CmuxNextDesign
public import Observation

/// The omnibar's sizes at one density (https://github.com/manaflow-ai/cmux/issues/28734): the bar,
/// its text, the toolbar buttons beside it and their icons. Standard (the `compact` preset, level 0,
/// the default) is the Helium bar: a 28 pt bar and buttons, 14 pt text, 13 pt chip icons, 20 pt
/// toolbar icons, 18 pt trailing icons. Comfortable (level 1) is Chrome's roomier 34 pt bar. Other
/// densities sit on the same line by their level (`DensityTokens.resolve`).
///
/// `browser.omnibar.height` and `browser.omnibar.fontSize` (``OmnibarGlassAppearance``) override the
/// bar height and text size; unset, they follow density. The bar is never shorter than its text
/// needs (`minimumBarHeight`). The toolbar page (webviews/src/pages/browser-toolbar) draws with these
/// numbers (``BrowserToolbarWebView``); the native row takes its height from them.
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
    /// The bookmark star's drawing side: `toolbarIconSize` (one ink box with the toolbar's glyphs),
    /// clamped to the star's button, `trailingIconSize + 2`.
    public var starIconSize: CGFloat { min(toolbarIconSize, trailingIconSize + 2) }

    /// `browser.omnibar.height`'s allowed range in points (`BrowserOmnibarSetting.heightRange`).
    public static let heightRange: ClosedRange<Double> = 20...56
    /// `browser.omnibar.fontSize`'s allowed range in points (`BrowserOmnibarSetting.fontSizeRange`).
    public static let fontSizeRange: ClosedRange<Double> = 10...24
    /// Space the bar keeps above and below its text line.
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
        buttonSize = tokens.toolbarButtonSize
        iconPointSize = min(tokens.resolve(compact: 13, comfortable: 15), ((barHeight - 8) / 1.2).rounded(.down))
        toolbarIconSize = min(tokens.toolbarGlyphSize, buttonSize - 4)
        trailingIconSize = min(tokens.resolve(compact: 18, comfortable: 20), barHeight - 6)
    }

    /// The shortest bar that holds a line of `fontSize` text with `textClearance` around it.
    public static func minimumBarHeight(fontSize: CGFloat) -> CGFloat {
        (fontSize * 1.25).rounded(.up) + textClearance
    }

    /// The metrics chrome draws now: the active density and cmux.json's overrides. Reading it in
    /// an Observation-tracked scope re-applies on a density or override change.
    @MainActor public static var current: OmnibarMetrics {
        let overrides = OmnibarGlassAppearance.current
        return OmnibarMetrics(tokens: Metrics.tokens, height: overrides.height, fontSize: overrides.fontSize,
                              textScale: Typography.userScale)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// How the omnibar's bar draws its fill (cmux.json `browser.omnibar.glass`, `glassTint`,
/// `glassTintStrength`, `cornerRadius`, `shadow`, `backgroundOpacity`): the flat theme fill (the
/// default), or none at all (transparent). The toolbar page draws it.
public nonisolated struct OmnibarGlassLook: Sendable, Hashable {
    public enum Material: String, Sendable, CaseIterable {
        /// No fill: what is behind the bar shows through; only hover, the focus ring and the card draw.
        case transparent
        /// The flat theme fill: a tonal step over the toolbar (the default).
        case off
        case regular
        case clear
    }

    public enum Tint: String, Sendable, CaseIterable {
        case background
        case accent
        case none
    }

    public var material: Material
    public var tint: Tint
    /// Tint opacity, 0 to 1.
    public var tintStrength: Double
    /// Corner radius in points; nil follows the theme's bar radius. Values past half the bar height draw a capsule.
    public var cornerRadius: Double?
    public var shadow: Bool
    /// How much the flat fill covers a see-through window behind it, 0 to 1.
    public var backgroundOpacity: Double

    public init(material: Material = .off, tint: Tint = .background, tintStrength: Double = 0.35,
                cornerRadius: Double? = nil, shadow: Bool = false, backgroundOpacity: Double = 0) {
        self.material = material
        self.tint = tint
        self.tintStrength = min(max(tintStrength, 0), 1)
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
    }

    /// The flat theme fill, theme radius, no shadow, following the window's opacity.
    public static let standard = OmnibarGlassLook()

    /// The look in effect now (cmux.json).
    @MainActor public static var current: OmnibarGlassLook { OmnibarGlassAppearance.current.look }

    /// The bar's corner radius at `barHeight`.
    @MainActor func resolvedCornerRadius(barHeight: CGFloat) -> CGFloat {
        min(CGFloat(cornerRadius ?? Double(Metrics.cornerRadius)), barHeight / 2)
    }
}

/// The look and size cmux.json asks for, written by the App on every settings load
/// (`BrowserOmnibarPreference`) and read by every toolbar, which follows it live.
@MainActor @Observable
public final class OmnibarGlassAppearance {
    public static let shared = OmnibarGlassAppearance()
    public private(set) var look = OmnibarGlassLook.standard
    /// `browser.omnibar.height` and `fontSize` in points; nil follows density (`OmnibarMetrics.current`).
    public private(set) var height: Double?
    public private(set) var fontSize: Double?

    init() {}

    /// The appearance chrome reads: a scoped one (tests), else `shared`.
    public static var current: OmnibarGlassAppearance { scoped ?? shared }

    /// Sets the bar's size overrides; nil follows density. Unchanged values notify nothing.
    public func applySize(height: Double?, fontSize: Double?) {
        if self.height != height { self.height = height }
        if self.fontSize != fontSize { self.fontSize = fontSize }
    }

    /// cmux.json's `browser.omnibar` look keys (`BrowserOmnibarSetting`): an unknown word keeps the
    /// default; `cornerRadius` nil is the theme's, infinite is a capsule.
    public func apply(glass: String, tint: String, tintStrength: Double, cornerRadius: Double?, shadow: Bool,
                      backgroundOpacity: Double = 0) {
        let next = OmnibarGlassLook(material: .init(rawValue: glass) ?? .off, tint: .init(rawValue: tint) ?? .background,
                                    tintStrength: tintStrength, cornerRadius: cornerRadius.map { $0.isFinite ? $0 : 999 },
                                    shadow: shadow, backgroundOpacity: backgroundOpacity)
        if look != next { look = next }
    }
}

nonisolated extension OmnibarGlassAppearance {
    /// An appearance code inside `$scoped.withValue` reads instead of `shared` (task-local).
    @TaskLocal static var scoped: OmnibarGlassAppearance?
}

/// The toolbar row's geometry (Helium's spacing, Lawrence 2026-10-20: "match Helium not Chrome"),
/// at the density and `browser.omnibar.*` sizes in effect. The native row takes its height from it;
/// the toolbar page lays out the controls with the same numbers (``BrowserToolbarWebView``).
@MainActor
enum ToolbarRowMetrics {
    /// Base padding: most spacing is a multiple of it (Helium's `kHeliumBasePadding`, 3).
    static let basePadding: CGFloat = 3
    static var metrics: OmnibarMetrics { .current }
    static var barHeight: CGFloat { metrics.barHeight }
    static var buttonSize: CGFloat { metrics.buttonSize }

    /// The browser chrome's one vertical gap (R101), the pane chrome's tab gap.
    static func chromeGap(scale: CGFloat) -> CGFloat { PaneChromeMetrics.current.tabGap(scale: scale) }

    /// Space the toolbar leaves above the omnibar: none, unless the pane is outlined, then one
    /// `chromeGap` below the outline's top line (Lawrence 2026-10-19).
    static func toolbarTopPadding(scale: CGFloat) -> CGFloat {
        guard Metrics.paneBorder == .subtle else { return 0 }
        return (Metrics.paneBorderWidth ?? 1 / max(scale, 1)) + chromeGap(scale: scale)
    }

    /// The row's content height: the toolbar buttons beside the omnibar, or the bar alone.
    static func rowContentHeight(withButtons: Bool = true) -> CGFloat { withButtons ? max(barHeight, buttonSize) : barHeight }

    /// The omnibar's top in the row: the top padding, then half the difference to the buttons.
    static func barTop(scale: CGFloat, withButtons: Bool = true) -> CGFloat {
        toolbarTopPadding(scale: scale) + (rowContentHeight(withButtons: withButtons) - barHeight) / 2
    }

    /// Toolbar row: the top padding, the row's content, then `chromeGap` down to the page.
    static func toolbarHeight(scale: CGFloat, withButtons: Bool = true) -> CGFloat {
        toolbarTopPadding(scale: scale) + rowContentHeight(withButtons: withButtons) + chromeGap(scale: scale)
    }

    /// Leading inset: the pane's chrome line (`Metrics.paneChromeInset`).
    static var toolbarInset: CGFloat { Metrics.paneChromeInset }
    /// More's center on the pane's trailing control column (Lawrence msg 19627).
    static var toolbarTrailingInset: CGFloat { max(0, Metrics.paneTrailingControlCenter - buttonSize / 2) }
    static var buttonSpacing: CGFloat { basePadding }
    /// The square buttons' corner (their hover fill).
    static let buttonCornerRadius: CGFloat = 8
    /// Reload to the bar, the bar to the extensions (Helium's `kLocationBarMargin`).
    static var barMargin: CGFloat { 2 * basePadding }
    static var cornerRadius: CGFloat { OmnibarGlassLook.current.resolvedCornerRadius(barHeight: barHeight) }

    /// The numbers the toolbar and popup pages lay out with (`ToolbarMetrics` in toolbar/wire.ts).
    static func wire(scale: CGFloat, withButtons: Bool, barTop: CGFloat? = nil) -> [String: Any] {
        let metrics = self.metrics
        return [
            "bar": metrics.barHeight, "button": metrics.buttonSize, "fontSize": metrics.fontSize,
            "toolbarIcon": metrics.toolbarIconSize, "trailingIcon": metrics.trailingIconSize, "starIcon": metrics.starIconSize, "chipIcon": metrics.iconPointSize,
            "spacing": buttonSpacing, "margin": barMargin, "inset": toolbarInset, "trailingInset": toolbarTrailingInset,
            "barTop": barTop ?? self.barTop(scale: scale, withButtons: withButtons), "cornerRadius": cornerRadius,
            "preferredAddress": Metrics.tabMaxWidth, "minimumAddress": BrowserMetrics.minimumAddressWidth,
            "maxPinned": ExtensionActions.maxVisible,
        ]
    }
}
