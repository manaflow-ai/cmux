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
    /// The knobs below the picker (`OmnibarGlassKnobs`), changed live.
    case custom

    public var tunableTitle: String {
        switch self {
        case .flat: "Flat (no glass)"
        case .glass: "Glass (regular, radius 8)"
        case .capsule: "Capsule (regular, shadow)"
        case .clear: "Clear (clear glass, shadow)"
        case .custom: "Custom (the knobs below)"
        }
    }

    public var look: OmnibarGlassLook {
        switch self {
        case .flat: OmnibarGlassLook(material: .off)
        case .glass: .standard
        case .capsule: OmnibarGlassLook(material: .regular, tint: .background, tintStrength: 0.2, cornerRadius: 999, shadow: true)
        case .clear: OmnibarGlassLook(material: .clear, tint: .background, tintStrength: 0.12, cornerRadius: 10, shadow: true)
        case .custom: OmnibarGlassKnobs.look
        }
    }

    public static let tunable = Tunable<OmnibarGlassDesign>.choice(
        "browser.omnibar.glassDesign", .glass, "Omnibar glass design",
        help: "TEMPORARY (cx-gkz5 vote): Flat, Glass, Capsule or Clear, or Custom to set each knob below live.",
        default: .glass, code: "OmnibarGlassDesign.tunable")
}

// MARK: Debug knobs (cx-gkz5, Lawrence 2026-10-10: "add to debug settings so i can vary it")

nonisolated extension OmnibarGlassLook.Material: TunableChoice {
    public var tunableTitle: String {
        switch self {
        case .regular: "Regular glass"
        case .clear: "Clear glass"
        case .off: "Off (flat theme fill)"
        }
    }
}

nonisolated extension OmnibarGlassLook.Tint: TunableChoice {
    public var tunableTitle: String {
        switch self {
        case .background: "Theme background"
        case .accent: "Theme accent (gray when the theme has none)"
        case .none: "None"
        }
    }
}

/// How the Custom design rounds the bar.
public nonisolated enum OmnibarGlassRadiusMode: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The theme's bar radius (8 pt).
    case theme
    /// Fully round ends.
    case capsule
    /// The Corner radius knob.
    case points

    public var tunableTitle: String {
        switch self {
        case .theme: "Match theme (8 pt)"
        case .capsule: "Capsule"
        case .points: "Corner radius knob"
        }
    }
}

/// What the bar shows behind its glass while comparing looks. The toolbar is
/// one flat theme color, so glass over it looks nearly flat; a backdrop
/// gives the glass something to refract.
public nonisolated enum OmnibarGlassBackdrop: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The toolbar as it is.
    case none
    /// A gradient of the theme's ANSI colors.
    case gradient
    /// Diagonal stripes of the theme's ANSI colors and its text color.
    case stripes

    public var tunableTitle: String {
        switch self {
        case .none: "None (the toolbar)"
        case .gradient: "Theme color gradient"
        case .stripes: "Theme color stripes"
        }
    }
}

/// The live knobs of the Custom omnibar design, in Debug Settings > Glass
/// and Overlays next to the design picker. Plain tunables (data in the
/// tunable registry), so every Debug Settings front end lists them.
nonisolated enum OmnibarGlassKnobs {
    static let style = Tunable<OmnibarGlassLook.Material>.choice(
        "browser.omnibar.glass.style", .glass, "Omnibar glass: style",
        help: "Custom design only. Regular or clear Liquid Glass (a blur before macOS 26), or off.",
        default: .regular, code: "OmnibarGlassKnobs.style")
    static let tint = Tunable<OmnibarGlassLook.Tint>.choice(
        "browser.omnibar.glass.tint", .glass, "Omnibar glass: tint",
        help: "Custom design only. The color over the glass, from the terminal theme.",
        default: .background, code: "OmnibarGlassKnobs.tint")
    static let tintStrength = Tunable<Double>.number(
        "browser.omnibar.glass.tintStrength", .glass, "Omnibar glass: tint strength",
        help: "Custom design only. Tint opacity.", default: 0.35, range: 0...1, step: 0.05, unit: .fraction,
        code: "OmnibarGlassKnobs.tintStrength")
    static let radiusMode = Tunable<OmnibarGlassRadiusMode>.choice(
        "browser.omnibar.glass.radiusMode", .glass, "Omnibar glass: corners",
        help: "Custom design only. Match theme, capsule, or the Corner radius knob.",
        default: .theme, code: "OmnibarGlassKnobs.radiusMode")
    static let radius = Tunable<Double>.number(
        "browser.omnibar.glass.radius", .glass, "Omnibar glass: corner radius",
        help: "Custom design with corners set to the knob. Points.", default: 8, range: 0...16, step: 1, unit: .points,
        code: "OmnibarGlassKnobs.radius")
    static let shadow = Tunable<Bool>.toggle(
        "browser.omnibar.glass.shadow", .glass, "Omnibar glass: shadow",
        help: "Custom design only. A soft shadow under the bar.", default: false, code: "OmnibarGlassKnobs.shadow")
    static let backdrop = Tunable<OmnibarGlassBackdrop>.choice(
        "browser.omnibar.glass.backdrop", .glass, "Omnibar glass: backdrop",
        help: "Any design. Draws theme colors behind the bar so the glass has something to refract; the toolbar alone is one flat color.",
        default: .none, code: "OmnibarGlassKnobs.backdrop")

    /// The Custom design's look from the knobs.
    static var look: OmnibarGlassLook {
        let radius: Double? = switch radiusMode.value {
        case .theme: nil
        case .capsule: 999
        case .points: self.radius.value
        }
        return OmnibarGlassLook(material: style.value, tint: tint.value, tintStrength: tintStrength.value,
                                cornerRadius: radius, shadow: shadow.value)
    }

    /// The picker and every knob, in Debug Settings order.
    static var descriptors: [TunableDescriptor] {
        [OmnibarGlassDesign.tunable.descriptor, style.descriptor, tint.descriptor, tintStrength.descriptor,
         radiusMode.descriptor, radius.descriptor, shadow.descriptor, backdrop.descriptor]
    }
}

extension OmnibarGlassDesign {
    /// The design picker and the Custom design's knobs, for the tunable
    /// registry (Debug Settings > Glass and Overlays).
    public static var debugDescriptors: [TunableDescriptor] { OmnibarGlassKnobs.descriptors }
}
