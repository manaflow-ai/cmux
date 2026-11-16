/// The built-in densities, densest first (Austin 2026-11-05: Ultra-compact, Compact, Default,
/// Comfortable, Spacious). Default (raw value `cozy`, kept so saved files and CLI names still work)
/// is the fresh-install density. Targets (Lawrence 2026-11-13): Compact is 20 pt tall everywhere,
/// Default's browser chrome is Helium's (28 pt tabs and omnibar 3 pt apart) with the ChatGPT app's 14 pt text (Lucas
/// 2026-11-13, measured in the app: sidebar rows and prompt 14 pt), Comfortable sits between, Spacious is Chrome's room
/// (34 pt tabs and omnibar 6 pt apart) with Helium's shapes and bigger text.
public nonisolated enum DensityPreset: String, Sendable, CaseIterable {
    case ultraCompact
    case compact
    case cozy
    case comfortable
    case spacious

    /// The preset's token set.
    public var tokens: DensityTokens {
        switch self {
        // A tab pill, the omnibar and the toolbar buttons share one height (`Metrics.chromeRowHeight`): the density's
        // `browserRowHeight`, with one gap, `browserRowGap`, above the pills, under them and under the omnibar
        // (`Metrics.tabStripHeight` sizes the strip for it; `HeliumDensityGeometryTests`). Default is Helium's (28 pt rows 3 pt apart, 65 pt of top
        // chrome), Compact the same at 20 pt rows, Spacious Chrome's sizes (34 pt rows 6 pt apart) with Helium's shapes,
        // Comfortable between (Lawrence 2026-11-13, density thread). The sidebar keeps its own rows.
        case .ultraCompact: DensityTokens(id: rawValue, name: "Ultra-compact", level: -0.5, spacing: 0.75, fontSize: 11,
                                          tokens: ["tabStripHeight": 26])
        case .compact: DensityTokens(id: rawValue, name: "Compact",
                                     tokens: ["sidebarRowHeight": 20, "browserRowHeight": 20, "browserRowGap": 2, "panePadding": 2])
        case .cozy: DensityTokens(id: rawValue, name: "Default", level: 0.5, fontSize: 14,
                                  tokens: ["sidebarRowHeight": 28, "browserRowHeight": 28, "browserRowGap": 3, "panePadding": 3])
        case .comfortable: DensityTokens(id: rawValue, name: "Comfortable", level: 1.25, spacing: 1.1, fontSize: 14,
                                         tokens: ["iconSize": 20, "smallIconSize": 16, "browserRowHeight": 31, "browserRowGap": 4,
                                                  "panePadding": 4])
        case .spacious: DensityTokens(id: rawValue, name: "Spacious", level: 2.25, spacing: 1.35, fontSize: 16,
                                      tokens: ["iconSize": 24, "smallIconSize": 20, "browserRowHeight": 34, "browserRowGap": 6,
                                               "panePadding": 6, "omnibarChromeColumn": 1])
        }
    }
}
