/// Settings > Advanced > Experiments, `experiments.agentBadges` and `experiments.agentBadgesBeam` (taste build 5,
/// 2026-11-19): agent counts and status on the tab strip and the sidebar. `off` (the default) is the shipped tabs and
/// rows. `pills`: a tab shows a neutral count pill (unread agent messages plus pending approvals) in a slot its width
/// always reserves, so no tab moves as the count comes and goes, and a sidebar row shows one tinted status pill
/// (Running, Needs approval, Done). `beam`: `pills`, plus a thin light that travels along the edge of a row whose agent
/// is running.
public nonisolated enum AgentBadgesExperiment: String, Hashable, Sendable, CaseIterable {
    case off
    case pills
    case beam

    /// The arm the two switches pick (`CmuxConfigSnapshot.experimentSwitches`, keyed by the path's last part): the
    /// beam switch does nothing while Agent Badges is off.
    public init(switches: [String: Bool]) {
        guard switches["agentBadges"] == true else {
            self = .off
            return
        }
        self = switches["agentBadgesBeam"] == true ? .beam : .pills
    }

    /// Whether tabs and rows draw the pills.
    public var showsPills: Bool { self != .off }
    /// Whether a running row draws the edge beam.
    public var showsBeam: Bool { self == .beam }
}
