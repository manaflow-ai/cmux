public import CmuxNextDesignTokens

/// The localized names of the built-in densities (Settings, the palette and `cmux density list`).
/// A custom density shows its own name.
public nonisolated struct DensityNames: Sendable {
    public init() {}

    /// A built-in's name.
    static func title(_ preset: DensityPreset) -> SettingText {
        switch preset {
        case .ultraCompact: SettingsText.keyed("settings.choice.ultraCompact", "Ultra-compact")
        case .compact: SettingsText.keyed("settings.choice.compact", "Compact")
        case .cozy: SettingsText.keyed("settings.choice.cozy", "Cozy")
        case .comfortable: SettingsText.keyed("settings.choice.comfortable", "Comfortable")
        case .spacious: SettingsText.keyed("settings.choice.spacious", "Spacious")
        }
    }

    /// The name `density` shows: a built-in's localized name, else its own.
    public func name(_ density: DensityTokens) -> String {
        DensityPreset(rawValue: density.id).map { Self.title($0).text } ?? density.name
    }
}
