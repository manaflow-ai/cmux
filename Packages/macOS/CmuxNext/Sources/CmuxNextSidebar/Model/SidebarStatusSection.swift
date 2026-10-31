/// Group by Status's section of a workspace row (Debug `sidebar.groupByStatus`): the Priority view's state for the
/// row, in the Priority view's tier order (`AgentPriorityRanking.tier`). Not a classifier of its own: it reads the
/// state the row feed already gives the row from the Priority classifier, its chip (`SidebarWorkspace.agentChip`,
/// `SidebarLaneStatus.chip`: needs you, done, failed or lost, CI failing) and, without one, its working mark
/// (`agentWorking`), else idle. Cases in display order.
public nonisolated enum SidebarStatusSection: String, CaseIterable, Hashable, Sendable {
    case needsYou
    case done
    /// Failed or lost: the Priority view ranks them as one tier.
    case failed
    case ciFailing
    case working
    case idle

    public init(_ row: SidebarWorkspace) {
        switch row.agentChip {
        case .needsYou?: self = .needsYou
        case .done?: self = .done
        case .failed?, .lost?: self = .failed
        case .ciFailing?: self = .ciFailing
        case .working?: self = .working
        case .idle?, nil: self = row.agentWorking ? .working : .idle
        }
    }

    /// Needs you always shows its rows: what waits on the person never hides.
    public var collapses: Bool { self != .needsYou }
}
