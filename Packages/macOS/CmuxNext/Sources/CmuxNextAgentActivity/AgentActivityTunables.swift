public import CmuxNextDesign

/// Pane layout prototypes (`agentActivity.layout` in Debug Settings, DEV and
/// NIGHTLY only). Release builds always use `split`.
public nonisolated enum AgentActivityLayout: String, Sendable, CaseIterable, TunableChoice {
    /// Session list left; preview, filmstrip and event rows right.
    case split
    /// One timeline across all live sessions, a lane per agent.
    case timeline
    /// A wall of session tiles (latest frame, or live frame when watched).
    case grid

    public var tunableTitle: String {
        switch self {
        case .split: "Split (list + timeline)"
        case .timeline: "Lanes (all agents on one timeline)"
        case .grid: "Grid (session wall)"
        }
    }
}

/// Debug Settings declarations of the Agent activity pane.
public nonisolated enum AgentActivityTunables {
    public static let section = TunableSection(id: "agentActivity", title: "Agent Activity", symbol: "cursorarrow.click.2", order: 40)

    public static let layout = Tunable<AgentActivityLayout>.choice(
        "agentActivity.layout", section, "Layout", help: "Prototype layout of the Agent activity pane. Switches live.",
        default: .split, code: "AgentActivityTunables.layout")

    public static let filmstripHeight = Tunable<Double>.number(
        "agentActivity.filmstripHeight", section, "Filmstrip height", help: "Height of the thumbnail filmstrip.",
        default: 76, range: 40...160, step: 2, unit: .points, code: "AgentActivityTunables.filmstripHeight")

    public static var all: [TunableDescriptor] { [layout.descriptor, filmstripHeight.descriptor] }
}
