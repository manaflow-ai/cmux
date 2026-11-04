import CmuxNextDesign
import AppKit
public import Observation

/// How the omnibar's bar draws its material: the flat theme fill (the
/// default, cx-d0d.101: a tonal step of the theme text over the toolbar,
/// `AddressBarSurface`), none at all (transparent: the toolbar shows
/// through), or Liquid Glass on macOS 26 and later (`GlassPanelView`, which
/// falls back to `NSVisualEffectView` before it). The glass tint
/// comes from the Ghostty theme: its background, or its accent only when the
/// theme names one (no blue otherwise). Reduce Transparency draws the flat
/// fill instead of glass.
///
/// The look comes from cmux.json (`browser.omnibar.glass`, `glassTint`,
/// `glassTintStrength`, `cornerRadius`, `shadow`, `backgroundOpacity`; the App writes
/// `OmnibarGlassAppearance.shared`).
public nonisolated struct OmnibarGlassLook: Sendable, Hashable {
    public enum Material: String, Sendable, CaseIterable {
        /// No fill and no material: what is behind the bar shows through;
        /// only hover, the focus ring and the suggestion card draw.
        case transparent
        /// The flat theme fill: a tonal step over the toolbar (the default).
        case off
        case regular
        case clear
    }

    public enum Tint: String, Sendable, CaseIterable {
        /// The theme's background color.
        case background
        /// The theme's accent (its ANSI blue) when the theme names one, else
        /// its neutral focus gray.
        case accent
        /// No tint: the material alone.
        case none
    }

    public var material: Material
    public var tint: Tint
    /// Tint opacity, 0 to 1.
    public var tintStrength: Double
    /// Corner radius in points; nil follows the theme's bar radius. Values
    /// past half the bar height draw a capsule.
    public var cornerRadius: Double?
    public var shadow: Bool
    /// How much the flat fill covers a see-through window behind it, 0 to 1
    /// (0: as see-through as the window, down to the text's legibility floor).
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
    @MainActor public static var current: OmnibarGlassLook { OmnibarGlassAppearance.shared.look }

    /// The bar's corner radius at `barHeight`.
    @MainActor func resolvedCornerRadius(barHeight: CGFloat) -> CGFloat {
        min(CGFloat(cornerRadius ?? Double(OmnibarStyle.barCornerRadius)), barHeight / 2)
    }

    /// The glass tint in the active theme scope (read inside `performWithTheme`).
    // theme-scoped: its one caller (OmnibarViews.refresh) runs it inside performWithTheme
    @MainActor func tintColor(boost: Double = 0) -> NSColor? {
        let base: NSColor
        switch tint {
        case .none: return nil
        case .background: base = Palette.chromeBackground
        case .accent: base = Palette.hasThemeAccent ? Palette.highlight : Palette.focusRing
        }
        let alpha = min(max(tintStrength + boost, 0), 1)
        return base.withAlphaComponent(base.alphaComponent * CGFloat(alpha))
    }
}

/// The look and size cmux.json asks for, written by the App on every settings load
/// (`BrowserOmnibarPreference`) and read by every omnibar
/// (`OmnibarGlassLook.current`), which follows it live.
@MainActor @Observable
public final class OmnibarGlassAppearance {
    public static let shared = OmnibarGlassAppearance()
    public private(set) var look = OmnibarGlassLook.standard
    /// `browser.omnibar.height` and `fontSize` in points; nil follows density (`OmnibarMetrics.current`).
    public private(set) var height: Double?
    public private(set) var fontSize: Double?
    init() {}

    /// The appearance chrome reads: a scoped one (tests that change the bar's size without
    /// touching the app-wide `shared`), else `shared`.
    public static var current: OmnibarGlassAppearance { scoped ?? shared }

    /// Sets the bar's size overrides; nil follows density. Unchanged values notify nothing.
    public func applySize(height: Double?, fontSize: Double?) {
        if self.height != height { self.height = height }
        if self.fontSize != fontSize { self.fontSize = fontSize }
    }

    /// cmux.json's `browser.omnibar` look keys (`BrowserOmnibarSetting`):
    /// an unknown word keeps the default; `cornerRadius` nil is the theme's,
    /// infinite is a capsule.
    public func apply(glass: String, tint: String, tintStrength: Double, cornerRadius: Double?, shadow: Bool,
                      backgroundOpacity: Double = 0) {
        let next = OmnibarGlassLook(material: .init(rawValue: glass) ?? .off, tint: .init(rawValue: tint) ?? .background,
                                    tintStrength: tintStrength, cornerRadius: cornerRadius.map { $0.isFinite ? $0 : 999 },
                                    shadow: shadow, backgroundOpacity: backgroundOpacity)
        if look != next { look = next }
    }
}

nonisolated extension OmnibarGlassAppearance {
    /// An appearance code inside `$scoped.withValue` reads instead of `shared` (task-local, so it
    /// reaches only that scope and the tasks it starts, the omnibar's re-apply loops included).
    @TaskLocal static var scoped: OmnibarGlassAppearance?
}
