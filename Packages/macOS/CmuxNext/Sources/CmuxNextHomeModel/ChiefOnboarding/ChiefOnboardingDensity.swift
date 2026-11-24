/// The densities Meet Chief offers (`appearance.density`): the three middle presets, so a first run picks among
/// few. The raw values are the setting's (`DensityPreset`); Settings > Appearance has the rest.
public enum ChiefOnboardingDensity: String, CaseIterable, Hashable, Sendable {
    /// Smaller rows and text.
    case compact
    /// The default.
    case cozy
    /// Roomier rows and larger text.
    case comfortable
}
