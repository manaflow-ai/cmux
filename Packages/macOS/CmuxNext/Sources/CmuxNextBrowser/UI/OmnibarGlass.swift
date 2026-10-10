public import CmuxNextDesign
import AppKit

/// How the omnibar's bar draws its material: Liquid Glass on macOS 26 and
/// later (`GlassPanelView`, which falls back to `NSVisualEffectView` before
/// it), or the flat theme fill. The tint comes from the Ghostty theme: its
/// background, or its accent only when the theme names one (no blue
/// otherwise). Reduce Transparency always draws the flat fill.
///
/// Slice 1 (cx-gkz5): the look comes from the TEMPORARY Debug
/// Settings design picker `browser.omnibar.glassDesign`. Slice 2 maps the
/// `browser.omnibar.glass*` settings onto this struct.
public nonisolated struct OmnibarGlassLook: Sendable, Hashable {
    public enum Material: String, Sendable, CaseIterable {
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

    public init(material: Material = .regular, tint: Tint = .background, tintStrength: Double = 0.35,
                cornerRadius: Double? = nil, shadow: Bool = false) {
        self.material = material
        self.tint = tint
        self.tintStrength = min(max(tintStrength, 0), 1)
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    /// Regular glass tinted from the theme background, theme radius, no shadow.
    public static let standard = OmnibarGlassLook()

    /// The look in effect now (the design picker; slice 2: the settings).
    public static var current: OmnibarGlassLook { OmnibarGlassDesign.tunable.value.look }

    /// The bar's corner radius at `barHeight`.
    @MainActor func resolvedCornerRadius(barHeight: CGFloat) -> CGFloat {
        min(CGFloat(cornerRadius ?? Double(OmnibarStyle.barCornerRadius)), barHeight / 2)
    }

    /// The glass tint in the active theme scope (read inside `performWithTheme`).
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

/// The omnibar glass variations Lawrence compares (TEMPORARY Debug Settings
/// picker `browser.omnibar.glassDesign`, cx-gkz5): after his pick
/// the picker and the losers go, and the winner becomes the settings
/// default.
public nonisolated enum OmnibarGlassDesign: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The flat theme fill, as before glass.
    case flat
    /// Regular glass, theme background tint 35%, theme radius 8, no shadow.
    case glass
    /// Regular glass capsule, theme background tint 20%, soft shadow.
    case capsule
    /// Clear glass, light theme background tint 12%, radius 10, soft shadow.
    case clear

    public var tunableTitle: String {
        switch self {
        case .flat: "Flat (no glass)"
        case .glass: "Glass (regular, radius 8)"
        case .capsule: "Capsule (regular, shadow)"
        case .clear: "Clear (clear glass, shadow)"
        }
    }

    public var look: OmnibarGlassLook {
        switch self {
        case .flat: OmnibarGlassLook(material: .off)
        case .glass: .standard
        case .capsule: OmnibarGlassLook(material: .regular, tint: .background, tintStrength: 0.2, cornerRadius: 999, shadow: true)
        case .clear: OmnibarGlassLook(material: .clear, tint: .background, tintStrength: 0.12, cornerRadius: 10, shadow: true)
        }
    }

    public static let tunable = Tunable<OmnibarGlassDesign>.choice(
        "browser.omnibar.glassDesign", .glass, "Omnibar glass design",
        help: "TEMPORARY (cx-gkz5 vote): Flat, Glass, Capsule or Clear.",
        default: .glass, code: "OmnibarGlassDesign.tunable")
}
