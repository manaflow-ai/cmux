public import CmuxNextDesign
import CmuxNextPages

/// Debug Settings declarations of the agent pane (DEV and NIGHTLY).
public nonisolated struct AgentPaneTunables {
    public nonisolated init() {}
    /// The agent pane move (react-pages.md): host new agent tabs on the shared page host
    /// (`cmux-page://cmux.agent/`) instead of the pane's own host. Off until the move is done; this
    /// tunable goes with the old host (P5).
    public static let pageHost = Tunable<Bool>.toggle(
        "agent.pageHost", PageTunables.section, "Agent pane on the page host",
        help: "New agent tabs load cmux-page://cmux.agent/ on the shared page host.",
        default: false, code: "AgentPaneTunables.pageHost")

    /// The New Tab page's style switch look (Leo 2026-10-14 compares them before one ships). The
    /// page draws its default for no override, so only an override is sent (`AgentPaneNewTab.styleSwitch`).
    public static let newTabStyleSwitch = Tunable<AgentPaneNewTabStyleSwitch>.choice(
        "newTab.styleSwitch", .tabs, "New tab style switch",
        help: "How the New Tab page shows its style switch. Applies to the next new tab.",
        default: .hint, code: "AgentPaneTunables.newTabStyleSwitch")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, newTabStyleSwitch.descriptor] }
}

/// The New Tab page's style switch looks (webviews newtab/templates.ts STYLE_SWITCHES).
public nonisolated enum AgentPaneNewTabStyleSwitch: String, Sendable, CaseIterable, TunableChoice {
    case hint, dots, strip, names

    public var tunableTitle: String {
        switch self {
        case .hint: "Dots that name a pick"
        case .dots: "Dots (before #20127)"
        case .strip: "Layout sketches"
        case .names: "Style names (#20336)"
        }
    }
}
