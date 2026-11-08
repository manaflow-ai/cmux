/// `home.chiefDock.*` in cmux.json: the Chief panel (user 2026-11-06). The Chief chat floats over the workspace a
/// window shows, or docks to an edge as a Chief-only pane once the person docks it; never over Home.
///
/// - `home.chiefDock.edge`: the edge the Chief docks to (its panel's Dock button): `left` (the default), `right`,
///   `top` or `bottom`.
/// - `home.chiefDock.openBeside`: a workspace, tab or subagent link clicked in the Chief opens its workspace with the
///   Chief floating over it; on when unset.
public nonisolated struct ChiefDockSetting {
    public nonisolated init() {}
    /// `home.chiefDock.edge`.
    public static let edgePath = ["home", "chiefDock", "edge"]
    /// `home.chiefDock.openBeside`.
    public static let openBesidePath = ["home", "chiefDock", "openBeside"]
    /// The edges, in the Settings choice's order.
    public static let edges = ["left", "right", "top", "bottom"]
    /// Left: most people keep the Chief on the left.
    public static let defaultEdge = "left"
    /// On: a link clicked in the Chief opens its workspace with the Chief floating over it.
    public static let defaultOpenBeside = true

    /// The edge; one that is not an edge is the default plus a diagnostic.
    static func parseEdge(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: edgePath) else { return (defaultEdge, nil) }
        guard let edge = value.stringValue?.lowercased(), edges.contains(edge) else {
            return (defaultEdge, SettingsDiagnostic(kind: .invalidValue, path: edgePath.joined(separator: "."),
                                                    message: "expected one of " + edges.joined(separator: ", ")))
        }
        return (edge, nil)
    }
}
