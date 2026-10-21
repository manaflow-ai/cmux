/// The built-in densities, densest first.
public nonisolated enum DensityPreset: String, Sendable, CaseIterable {
    case ultraCompact
    case compact
    case cozy
    case comfortable
    case spacious

    /// The preset's token set.
    public var tokens: DensityTokens {
        switch self {
        case .ultraCompact: DensityTokens(id: rawValue, name: "Ultra-compact", level: -0.5, spacing: 0.75)
        case .compact: DensityTokens(id: rawValue, name: "Compact")
        case .cozy: DensityTokens(id: rawValue, name: "Cozy", level: 0.5)
        case .comfortable: DensityTokens(id: rawValue, name: "Comfortable", level: 1)
        case .spacious: DensityTokens(id: rawValue, name: "Spacious", level: 1.75, spacing: 1.25)
        }
    }
}
