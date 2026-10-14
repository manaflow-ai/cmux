public import CmuxNextDesign

/// How a group draws its header and members (`sidebar.groupLook`, a Debug
/// Settings prototype for the sidebar groupings Thunderdome).
public nonisolated enum SidebarGroupLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The Chrome tab group: the colored header bar and a straight line down the members (the default).
    case chrome
    /// Zen and Dia: a quiet name beside a small color square, and one soft
    /// band in the group's color behind the header and its members.
    case zen
    /// A tree: the header bar, then a line with a short elbow into each member.
    case elbow

    public var tunableTitle: String {
        switch self {
        case .chrome: "Chrome bar and line"
        case .zen: "Zen band"
        case .elbow: "Elbow connectors"
        }
    }
}
