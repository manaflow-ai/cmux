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

    /// The sidebar's Lanes item and the lanes view show this Mac's own sessions; on, also the
    /// acpmux peers' lanes and coordinators' child sessions (`AgentLaneStore.shown`).
    public static let lanesShowFleet = Tunable<Bool>.toggle(
        "agentActivity.lanesShowFleet", section, "Lanes: show fleet and child lanes",
        help: "The Lanes item and view also count acpmux peers' lanes and sessions a coordinator started (mux.parent).",
        default: false, code: "AgentActivityTunables.lanesShowFleet")

    public static var all: [TunableDescriptor] { [layout.descriptor, lanesShowFleet.descriptor] }
}
