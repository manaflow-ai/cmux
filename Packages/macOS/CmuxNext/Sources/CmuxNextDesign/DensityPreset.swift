/// The built-in densities, densest first (Austin 2026-11-05: Ultra-compact, Compact, Default,
/// Comfortable, Spacious). Default (raw value `cozy`, kept so saved files and CLI names still work)
/// is the fresh-install density: the text size and row height of the ChatGPT and Codex desktop
/// apps (13 pt text, 28 pt rows). Ultra-compact and Compact are unchanged; Comfortable and
/// Spacious sit above Default.
public nonisolated enum DensityPreset: String, Sendable, CaseIterable {
    case ultraCompact
    case compact
    case cozy
    case comfortable
    case spacious

    /// The preset's token set.
    public var tokens: DensityTokens {
        switch self {
        // Lucas 2026-11-12 ("Densities still look bad. Try text size and icon size, not only spacing."): each density
        // also steps the text (11 to 15) and the icons (12 to 24, the icon scale); Default keeps its sizes.
        case .ultraCompact: DensityTokens(id: rawValue, name: "Ultra-compact", level: -0.5, spacing: 0.75, fontSize: 11,
                                          tokens: ["iconSize": 12, "smallIconSize": 12])
        case .compact: DensityTokens(id: rawValue, name: "Compact", tokens: ["iconSize": 14, "smallIconSize": 12])
        case .cozy: DensityTokens(id: rawValue, name: "Default", level: 0.5, fontSize: 13)
        case .comfortable: DensityTokens(id: rawValue, name: "Comfortable", level: 1.25, spacing: 1.1, fontSize: 14,
                                         tokens: ["iconSize": 20, "smallIconSize": 16])
        case .spacious: DensityTokens(id: rawValue, name: "Spacious", level: 2.25, spacing: 1.35, fontSize: 15,
                                      tokens: ["iconSize": 24, "smallIconSize": 20])
        }
    }
}
