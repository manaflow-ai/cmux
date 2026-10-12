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

    /// Parses every pane placement key into `snapshot`.
    static func parsePanePlacement(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        var diagnostics: [SettingsDiagnostic] = []
        snapshot.newPanePlacement = ColumnLayoutSettings.choice(root, newPanePlacementPath, fallback: newPanePlacementFallback,
                                                                diagnostics: &diagnostics)
        if let value = root.value(at: tileBrowsersPath) {
            if let on = value.boolValue {
                snapshot.tileBrowsers = on
            } else {
                snapshot.tileBrowsers = tileBrowsersFallback
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: tileBrowsersPath.joined(separator: "."),
                                                      message: "expected true or false"))
            }
        } else {
            snapshot.tileBrowsers = tileBrowsersFallback
        }
        snapshot.diagnostics += diagnostics
    }
}
