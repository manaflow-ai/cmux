/// `home.chiefDock.*` in cmux.json: the Chief window dock (user 2026-11-05). Home's Chief docks to an edge of the
/// window, as a workspace held by the window frame (plans/cmux-next/docked-workspace-DESIGN.md), while the rest
/// of the window shows the workspace the sidebar or a link selects; the Chief's view stays mounted, so its draft,
/// scroll position and selection are kept. Only the person docks it (Open Chief Dock, Cmd-I) and undocks it (Undock
/// Chief); no link click does (cmux#37372, which retired `home.chiefDock.openBeside`).
///
/// - `home.chiefDock.edge`: the edge Open Chief Dock (Cmd-I) docks it to: `left` (the default), `right`, `top` or
///   `bottom`.
public nonisolated struct ChiefDockSetting {
    public nonisolated init() {}
    /// `home.chiefDock.edge`.
    public static let edgePath = ["home", "chiefDock", "edge"]
    /// The edges, in the Settings choice's order.
    public static let edges = ["left", "right", "top", "bottom"]
    /// Left: most people keep the Chief on the left.
    public static let defaultEdge = "left"

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
