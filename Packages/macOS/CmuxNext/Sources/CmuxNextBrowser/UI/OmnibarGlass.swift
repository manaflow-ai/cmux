import CmuxNextDesign
import AppKit
public import Observation

/// How the omnibar's bar draws its material: none at all (the default,
/// Lawrence 2026-10-13: flat and clear, the toolbar shows through), Liquid
/// Glass on macOS 26 and later (`GlassPanelView`, which falls back to
/// `NSVisualEffectView` before it), or the flat theme fill. The glass tint
/// comes from the Ghostty theme: its background, or its accent only when the
/// theme names one (no blue otherwise). Reduce Transparency draws the flat
/// fill instead of glass.
///
/// The look comes from cmux.json (`browser.omnibar.glass`, `glassTint`,
/// `glassTintStrength`, `cornerRadius`, `shadow`; the App writes
/// `OmnibarGlassAppearance.shared`).
public nonisolated struct OmnibarGlassLook: Sendable, Hashable {
    public enum Material: String, Sendable, CaseIterable {
        /// No fill and no material: what is behind the bar shows through;
        /// only hover, the focus ring and the suggestion card draw.
        case transparent
        /// The flat theme fill (the look before glass).
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

    public init(material: Material = .transparent, tint: Tint = .background, tintStrength: Double = 0.35,
                cornerRadius: Double? = nil, shadow: Bool = false) {
        self.material = material
        self.tint = tint
        self.tintStrength = min(max(tintStrength, 0), 1)
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    /// Transparent (flat and clear), theme radius, no shadow.
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

/// The look cmux.json asks for, written by the App on every settings load
/// (`BrowserOmnibarPreference`) and read by every omnibar
/// (`OmnibarGlassLook.current`), which follows it live.
@MainActor @Observable
public final class OmnibarGlassAppearance {
    public static let shared = OmnibarGlassAppearance()
    public private(set) var look = OmnibarGlassLook.standard
    private init() {}

    /// cmux.json's `browser.omnibar` look keys (`BrowserOmnibarSetting`):
    /// an unknown word keeps the default; `cornerRadius` nil is the theme's,
    /// infinite is a capsule.
    public func apply(glass: String, tint: String, tintStrength: Double, cornerRadius: Double?, shadow: Bool) {
        let next = OmnibarGlassLook(material: .init(rawValue: glass) ?? .transparent, tint: .init(rawValue: tint) ?? .background,
                                    tintStrength: tintStrength, cornerRadius: cornerRadius.map { $0.isFinite ? $0 : 999 },
                                    shadow: shadow)
        if look != next { look = next }
    }
}
