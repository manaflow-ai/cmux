public import CmuxNextDesignTokens
/// How web glass surfaces bend the wallpaper behind them (plans/cmux-next/glass-lens-DESIGN.md):
/// the Debug Settings choice `glass.lens` (DEV and NIGHTLY), outside the settings schema until the
/// lens is promoted. `plain` (the default, the look before the lens) only blurs it, `lens` refracts
/// it at the rim, `spectrum` adds a chromatic split at the rim. Leo 2026-10-21: the lens is a
/// toggle to see and feel before it is the default.
public nonisolated enum GlassLensMode: String, Sendable, CaseIterable, Codable, TunableChoice {
    case lens
    case plain
    case spectrum

    public var tunableTitle: String {
        switch self {
        case .lens: "Lens (refracts at the rim)"
        case .plain: "Plain Glass (blur only)"
        case .spectrum: "Spectrum (lens with a chromatic rim)"
        }
    }

    /// Debug Settings > Glass and Overlays > Liquid Glass; Release keeps `plain`, since its store never activates.
    public static let tunable = Tunable<GlassLensMode>.choice(
        "glass.lens", .glass, "Liquid Glass",
        help: "How web glass bends the wallpaper behind it: plain glass (default) only blurs it, lens refracts it at the rim, spectrum adds a chromatic split. Reduce Transparency and Low Power Mode draw plain glass.",
        default: .plain, code: "GlassLensMode.tunable")

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
    /// The mode pages draw now: the `glass.lens` choice under the system's Reduce Transparency
    /// (or its Debug override) and Low Power Mode.
    @MainActor public static var current: GlassLensMode {
        current(store: .shared, reduceTransparency: .shared, lowPower: .system)
    }

    /// The mode pages draw from these sources.
    @MainActor public static func current(store: TunableStore, reduceTransparency: ReduceTransparency,
                                          lowPower: LowPowerMode) -> GlassLensMode {
        tunable.value(in: store).effective(reduceTransparency: reduceTransparency.isEnabled, lowPowerMode: lowPower.isEnabled)
    }

    /// Sets the `glass.lens` choice; the default removes the override.
    public static func choose(_ mode: GlassLensMode, in store: TunableStore = .shared) {
        if mode == tunable.defaultValue { store.reset([tunable.key]) } else { store.set(tunable.key, mode.tunableValue) }
    }
}
