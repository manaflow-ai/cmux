/// `appearance.glass` in cmux.json: how web glass surfaces bend the wallpaper behind them
/// (plans/cmux-next/glass-lens-DESIGN.md). `plain` (the default, the look before the lens) only
/// blurs it, `lens` (opt-in, Leo 2026-10-21) refracts it at the rim, `spectrum` adds a chromatic
/// split at the rim.
public nonisolated enum GlassLensMode: String, Sendable, CaseIterable, Codable {
    case lens
    case plain
    case spectrum

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
    /// The mode pages draw now: `DesignSettings.glass` under the system's Reduce Transparency
    /// (or its Debug override) and Low Power Mode.
    @MainActor public static var current: GlassLensMode {
        current(settings: .shared, reduceTransparency: .shared, lowPower: .system)
    }

    /// The mode pages draw from these sources.
    @MainActor public static func current(settings: DesignSettings, reduceTransparency: ReduceTransparency,
                                          lowPower: LowPowerMode) -> GlassLensMode {
        settings.glass.effective(reduceTransparency: reduceTransparency.isEnabled, lowPowerMode: lowPower.isEnabled)
    }
}
