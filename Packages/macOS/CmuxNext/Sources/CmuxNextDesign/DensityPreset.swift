/// The built-in densities, densest first (Austin 2026-11-05: Ultra-compact, Compact, Default,
/// Comfortable, Spacious). Default (raw value `cozy`, kept so saved files and CLI names still work)
/// is the fresh-install density. Targets (Lawrence 2026-11-13): Compact is 20 pt tall everywhere,
/// Default is Helium's room (30 pt tabs and omnibar, 36 pt strip) with the ChatGPT app's 14 pt text (Lucas
/// 2026-11-13, measured in the app: sidebar rows and prompt 14 pt), Comfortable is Chrome's room (34 pt omnibar) at
/// the same text, Spacious has bigger text.
public nonisolated enum DensityPreset: String, Sendable, CaseIterable {
    case ultraCompact
    case compact
    case cozy
    case comfortable
    case spacious

    /// The preset's token set.
    public var tokens: DensityTokens {
        switch self {
        // A tab pill, the omnibar, the toolbar buttons and a sidebar row share one height (`Metrics.chromeRowHeight`):
        // `sidebarRowHeight` sets it. Default's list row adds `space1` (the Codex fill, 28 + 2 = 30; Lucas 2026-11-13: 30 pt tabs).
        case .ultraCompact: DensityTokens(id: rawValue, name: "Ultra-compact", level: -0.5, spacing: 0.75, fontSize: 11)
        case .compact: DensityTokens(id: rawValue, name: "Compact", tokens: ["sidebarRowHeight": 20, "tabStripHeight": 26])
        case .cozy: DensityTokens(id: rawValue, name: "Default", level: 0.5, fontSize: 14,
                                  tokens: ["sidebarRowHeight": 28, "tabStripHeight": 36])
        case .comfortable: DensityTokens(id: rawValue, name: "Comfortable", level: 1.25, spacing: 1.1, fontSize: 14,
                                         tokens: ["iconSize": 20, "smallIconSize": 16])
        case .spacious: DensityTokens(id: rawValue, name: "Spacious", level: 2.25, spacing: 1.35, fontSize: 16,
                                      tokens: ["iconSize": 24, "smallIconSize": 20])
        }
    }
}
