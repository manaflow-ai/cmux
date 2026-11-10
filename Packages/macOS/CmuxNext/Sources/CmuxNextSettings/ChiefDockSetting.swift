// The paths, defaults and edges are generated from schemas/settings/source/home.json
// (Schema/SettingsSchema+Home.generated.swift).

/// `home.chiefDock.*` in cmux.json: the Chief panel (user 2026-11-06). The Chief chat floats over the workspace a
/// window shows, or docks to an edge as a Chief-only pane once the person docks it; never over Home.
///
/// - `home.chiefDock.edge`: the edge the Chief docks to (its panel's Dock button): `left` (the default), `right`,
///   `top` or `bottom`.
/// - `home.chiefPanel.style`: how the floating Chief looks: `composeBar` (the default: only the message box, which
///   grows into the chat with the keys), `pill`, `card`, `panel`, `bubble`, `seeThrough` (the bubbles over the
///   workspace, as in Messages) or `seeThroughBar` (its message box alone, which grows into it).
/// - `home.chiefPanel.seesScreen`: opening the floating Chief gives it one look at the screen; on when unset.
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

    /// The style; one that is not a style is the default plus a diagnostic.
    static func parseStyle(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: stylePath) else { return (styleDefault, nil) }
        guard let style = value.stringValue, styleValues.contains(style) else {
            return (styleDefault, SettingsDiagnostic(kind: .invalidValue, path: stylePath.joined(separator: "."),
                                                     message: "expected one of " + styleValues.joined(separator: ", ")))
        }
        return (style, nil)
    }
}
