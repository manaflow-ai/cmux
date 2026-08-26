import CmuxTerminalCore

/// Resolved durable and runtime font ownership for one configuration reload.
struct TerminalFontSizeConfigurationReloadResolvedTarget {
    let lineage: TerminalFontSizeLineage
    let durableRuntimePoints: Float32
    let retainsExplicitBase: Bool
}
