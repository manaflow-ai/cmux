public import CmuxNextDesign

nonisolated extension AgentPaneTunables {
    /// The New Tab page's style switch look. The page draws round for no override, so only an
    /// override is sent (`AgentPaneNewTab.styleSwitch`).
    public static let newTabStyleSwitch = Tunable<AgentPaneNewTabStyleSwitch>.choice(
        "newTab.styleSwitch", .tabs, "New tab style switch",
        help: "How the New Tab page shows its styles. Applies to the next new tab.",
        default: .round, code: "AgentPaneTunables.newTabStyleSwitch")
}

/// The New Tab page's style switch looks (webviews newtab/templates.ts STYLE_SWITCHES). Round is
/// the page's own look (#20473); the others are opt-in in Debug Settings (Lawrence 2026-10-14: no
/// Labs; a look moves to Settings once it earns it).
public nonisolated enum AgentPaneNewTabStyleSwitch: String, Sendable, CaseIterable, TunableChoice {
    case round, hint, dots, strip, names

    public var tunableTitle: String {
        switch self {
        case .round: "Round dots (#20473)"
        case .hint: "Dots that name a pick"
        case .dots: "Chip dots (before #20127)"
        case .strip: "Layout sketches"
        case .names: "Style names (#20336)"
        }
    }
}
