// The paths, defaults and edges are generated from schemas/settings/source/home.json
// (Schema/SettingsSchema+Home.generated.swift).

/// `home.chiefDock.*` in cmux.json: the Chief panel (user 2026-11-06). The Chief chat floats over the workspace a
/// window shows, or docks to an edge as a Chief-only pane once the person docks it; never over Home.
///
/// - `home.chiefDock.edge`: the edge the Chief docks to (its panel's Dock button): `left` (the default), `right`,
///   `top` or `bottom`.
/// - `home.chiefDock.openBeside`: a workspace, tab or subagent link clicked in the Chief opens its workspace with the
///   Chief floating over it; on when unset.
public nonisolated struct ChiefDockSetting {
    public nonisolated init() {}

    /// The edge; one that is not an edge is the default plus a diagnostic.
    static func parseEdge(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: edgePath) else { return (edgeDefault, nil) }
        guard let edge = value.stringValue?.lowercased(), edgeValues.contains(edge) else {
            return (edgeDefault, SettingsDiagnostic(kind: .invalidValue, path: edgePath.joined(separator: "."),
                                                    message: "expected one of " + edgeValues.joined(separator: ", ")))
        }
        return (edge, nil)
    }
}
