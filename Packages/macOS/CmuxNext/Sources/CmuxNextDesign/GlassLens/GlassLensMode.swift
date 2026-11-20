public import CmuxNextDesignTokens
public import Foundation
/// How web glass surfaces bend the wallpaper behind them (plans/cmux-next/glass-lens-DESIGN.md): the setting
/// `appearance.glass.composer.material` (``DesignSettings/glassLensMode``), in every build. `plain` (the default,
/// the look before the lens) only blurs it, `lens` refracts it at the rim, `spectrum` adds a chromatic split at the
/// rim. Leo 2026-10-21: the lens is a toggle to see and feel before it is the default; 2026-11-20, promoting it from
/// Debug Settings: "Like, why not offer the option? I think it looks neat. I like the refraction."
///
/// It was the Debug choice `glass.lens` (DEV and NIGHTLY) until 2026-11-20: ``retiredTunableKey`` names it, and a
/// Debug file that still holds lens or spectrum moves into the setting once (`SettingsController.moveRetiredGlassLens`).
public nonisolated enum GlassLensMode: String, Sendable, CaseIterable, Codable {
    case lens
    case plain
    case spectrum

    /// The Debug Settings key this setting replaced (a rename: its value moves into the setting once).
    public static let retiredTunableKey = "glass.lens"

    /// The mode a material value names: `lens` and `spectrum` refract; unset, `plain` or a material the web
    /// draws as plain glass (`frosted`, `glass-clear`, `translucent`) is plain.
    public init(material: String?) {
        self = material.flatMap(GlassLensMode.init(rawValue:)) ?? .plain
    }

    /// The retired Debug choice in the Debug Settings file at `url`, when it refracts (lens or spectrum): the value
    /// the one-time move gives the setting. Reads the file, so never on the main actor.
    public static func retiredChoice(inDebugFile url: URL) -> GlassLensMode? {
        let mode = GlassLensMode(material: TunableFile.readRaw(url)[retiredTunableKey] as? String)
        return mode.refracts ? mode : nil
    }

    /// The mode pages draw: `plain` under Reduce Transparency or Low Power Mode, else this one.
    public func effective(reduceTransparency: Bool, lowPowerMode: Bool) -> GlassLensMode {
        reduceTransparency || lowPowerMode ? .plain : self
    }

    /// Whether pages refract a wallpaper still (the host feeds them one, `GlassBackdropFeed`).
    public var refracts: Bool { self != .plain }

    /// The palette's Toggle Liquid Glass Lens: plain turns the lens on; lens or spectrum turn it off.
    public var lensToggled: GlassLensMode { self == .plain ? .lens : .plain }
}

extension GlassLensMode {
    /// The mode pages draw now: the setting (``DesignSettings/glassLensMode``) under the system's Reduce
    /// Transparency (or its Debug override) and Low Power Mode.
    @MainActor public static var current: GlassLensMode {
        current(chosen: DesignSettings.shared.glassLensMode, reduceTransparency: .shared, lowPower: .system)
    }

    /// The mode pages draw from these sources.
    @MainActor public static func current(chosen: GlassLensMode, reduceTransparency: ReduceTransparency,
                                          lowPower: LowPowerMode) -> GlassLensMode {
        chosen.effective(reduceTransparency: reduceTransparency.isEnabled, lowPowerMode: lowPower.isEnabled)
    }
}
