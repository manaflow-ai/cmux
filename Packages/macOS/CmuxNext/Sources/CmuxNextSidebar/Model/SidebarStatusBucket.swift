public import CmuxNextDesign

/// Group by Status's section of a workspace row (Debug `sidebar.groupByStatus`), from the
/// row's merged status (`SidebarWorkspace.activity`: acpmux turns, hooks, OSC 7501 and
/// `cmux status set` alike, so every harness sorts the same way). Cases in display order.
public nonisolated enum SidebarStatusBucket: String, CaseIterable, Hashable, Sendable {
    /// Waiting on the person (a permission, a question), or failed: never collapses.
    case needsYou
    /// An agent turn or a program's work runs.
    case working
    /// An agent at rest: its turn ended, or it waits for the next prompt.
    case done
    /// No agent in the workspace and nothing to report.
    case noAgent

    public init(_ row: SidebarWorkspace) {
        let hasAgent = row.agentBrand != nil || row.agentName != nil || row.rowKind == .agent
        switch row.activity {
        case .waiting, .error: self = .needsYou
        case .working: self = .working
        case .busy, .paused: self = hasAgent ? .working : .noAgent
        case .idle, .success: self = hasAgent ? .done : .noAgent
        }
    }

    /// Needs you always shows its rows: what waits on the person never hides.
    public var collapses: Bool { self != .needsYou }
}
