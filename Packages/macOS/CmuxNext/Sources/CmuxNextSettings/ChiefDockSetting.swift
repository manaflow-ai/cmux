// The paths, defaults and edges are generated from schemas/settings/source/home.json
// (Schema/SettingsSchema+Home.generated.swift).

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
