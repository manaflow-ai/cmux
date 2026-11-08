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
    /// `home.chiefDock.edge`.
    public static let edgePath = ["home", "chiefDock", "edge"]
    /// `home.chiefPanel.style`.
    public static let stylePath = ["home", "chiefPanel", "style"]
    /// The floating Chief's styles, in the Settings choice's order (the Layout package's `ChiefPanelStyle`).
    public static let styles = ["composeBar", "pill", "card", "panel", "bubble", "seeThrough", "seeThroughBar"]
    /// The compose bar: the least on screen that still takes a message (user 2026-11-07).
    public static let defaultStyle = "composeBar"
    /// `home.chiefPanel.seesScreen`: the floating Chief's eye; when on, opening the panel gives the Chief one look at
    /// the screen behind cmux (Share Screen with Chief's helper and grant, never a prompt).
    public static let seesScreenPath = ["home", "chiefPanel", "seesScreen"]
    /// On: the eye in the panel shows it, and a click turns it off (user 2026-11-07, default picked by the Chief).
    public static let defaultSeesScreen = true
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

    /// The style; one that is not a style is the default plus a diagnostic.
    static func parseStyle(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: stylePath) else { return (defaultStyle, nil) }
        guard let style = value.stringValue, styles.contains(style) else {
            return (defaultStyle, SettingsDiagnostic(kind: .invalidValue, path: stylePath.joined(separator: "."),
                                                     message: "expected one of " + styles.joined(separator: ", ")))
        }
        return (style, nil)
    }
}
