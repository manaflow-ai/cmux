/// Whether a setting has a palette row (`SettingsPaletteSource`).
public nonisolated enum SettingPaletteExposure: Sendable, Hashable {
    case exposed
    /// Kept out of the palette, with the reason.
    case hidden(String)
}
