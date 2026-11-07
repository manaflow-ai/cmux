/// `home.chiefDock.*` in cmux.json: the Chief window dock (user 2026-11-05). Home's Chief docks to an edge of the
/// window, as a workspace held by the window frame (plans/cmux-next/docked-workspace-DESIGN.md), while the rest
/// of the window shows the workspace the sidebar or a link selects; the Chief's view stays mounted, so its draft,
/// scroll position and selection are kept.
///
/// - `home.chiefDock.edge`: the edge Open Chief Dock (Cmd-I) and a link from the Chief dock it to: `left` (the
///   default), `right`, `top` or `bottom`.
/// - `home.chiefDock.openBeside`: a workspace, tab or subagent link clicked in the Chief shows its workspace beside
///   the docked Chief instead of in Home's place; off when unset (cmux#37365: the Chief is never pinned on screen
///   unless the person docks it, with Cmd-I or this setting).
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
    /// Off (cmux#37365, "i dont want this by default"): a link clicked in the Chief shows its workspace in Home's
    /// place, and the Chief docks only when the person asks (Open Chief Dock, Cmd-I) or turns this on.
    public static let defaultOpenBeside = false

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
