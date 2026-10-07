public import CmuxNextDesign

/// Where new panes open (`PanePlacement`): `layout.newPanePlacement` (tab or
/// split) and `layout.tileBrowsers` (browsers split too under split
/// placement). A missing key is the default with no diagnostic; a bad value
/// is the default plus a diagnostic.
nonisolated extension CmuxConfigSnapshot {
    public static let newPanePlacementPath = ["layout", "newPanePlacement"]
    public static let tileBrowsersPath = ["layout", "tileBrowsers"]

    public static let newPanePlacementFallback: NewPanePlacement = .tab
    /// Browser tiling stays opt-in.
    public static let tileBrowsersFallback = false

    /// RED STUB: parses nothing yet.
    static func parsePanePlacement(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {}
}
