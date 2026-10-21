public import CmuxNextDesign

/// Where new panes open (`PanePlacement`): `layout.newPanePlacement` (tab or
/// split) and `layout.tileBrowsers` (browsers split too under split
/// placement), `layout.linkPlacement` (``LinkPlacement``) and `layout.newTabPageFollowsLinkPlacement`. A missing key is the default with no diagnostic; a bad value
/// is the default plus a diagnostic.
nonisolated extension CmuxConfigSnapshot {
    public static let newPanePlacementPath = ["layout", "newPanePlacement"]
    public static let tileBrowsersPath = ["layout", "tileBrowsers"]
    public static let newTabPageFollowsLinkPlacementPath = ["layout", "newTabPageFollowsLinkPlacement"]

    public static let newPanePlacementFallback: NewPanePlacement = .tab
    /// Browser tiling stays opt-in.
    public static let tileBrowsersFallback = false
    /// A New Tab page's pick replaces the page in its pane unless the person opts in.
    public static let newTabPageFollowsLinkPlacementFallback = false

    /// Parses every pane placement key into `snapshot`.
    static func parsePanePlacement(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        var diagnostics: [SettingsDiagnostic] = []
        snapshot.newPanePlacement = ColumnLayoutSettings.choice(root, newPanePlacementPath, fallback: newPanePlacementFallback,
                                                                diagnostics: &diagnostics)
        snapshot.tileBrowsers = toggle(root, tileBrowsersPath, fallback: tileBrowsersFallback, diagnostics: &diagnostics)
        snapshot.newTabPageFollowsLinkPlacement = toggle(root, newTabPageFollowsLinkPlacementPath,
                                                         fallback: newTabPageFollowsLinkPlacementFallback, diagnostics: &diagnostics)
        snapshot.linkPlacement = ColumnLayoutSettings.choice(root, LinkPlacement.configPath, fallback: LinkPlacement.fallback,
                                                             diagnostics: &diagnostics)
        snapshot.diagnostics += diagnostics
    }

    /// The boolean at `path`; missing is `fallback`, a non-boolean is `fallback` plus a diagnostic.
    private static func toggle(_ root: JSONValue, _ path: [String], fallback: Bool, diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: path) else { return fallback }
        if let on = value.boolValue { return on }
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
        return fallback
    }
}
