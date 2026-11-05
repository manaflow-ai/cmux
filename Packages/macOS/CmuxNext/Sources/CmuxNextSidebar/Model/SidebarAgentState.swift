public import CmuxNextDesign

/// What a workspace's agents are doing, for the session tree's roll-ups (`sidebar.sessionTree`).
/// Stricter than the priority buckets (`SidebarPriorityBucket`): an unread mark alone is not
/// `blocked`, and a coordinator waiting on its own children is `idle`, not waiting on you.
public nonisolated enum SidebarAgentState: Int, Hashable, Sendable, Comparable {
    case idle
    /// It finished and the user has not read what it wrote.
    case finishedUnread
    /// A turn runs.
    case running
    /// The last turn failed, or the agent is gone without an answer.
    case failed
    /// A question or a permission waits for the user.
    case blocked

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `ws`'s state: `lane` (what acpmux decided for its agents) when it has one, upgraded to
    /// `finishedUnread` when the idle workspace has an unread mark. A workspace without a lane (a
    /// terminal agent reporting through hooks) reads its row: a hook's waiting or error, its work.
    public static func of(_ ws: SidebarWorkspace, lane: SidebarAgentState?) -> SidebarAgentState {
        if let lane {
            return lane == .idle && ws.unread.isUnread ? .finishedUnread : lane
        }
        switch ws.activity {
        case .waiting: return .blocked
        case .error: return .failed
        case .working, .busy, .paused: return .running
        case .idle, .success: break
        }
        if ws.agentWorking { return .running }
        return ws.unread.isUnread ? .finishedUnread : .idle
    }
}

/// A folded parent's descendants, counted by state: the chips on its row
/// ("1 failed, 2 blocked, 5 running, 3 unread"). Idle descendants are not counted by state;
/// `total` counts every descendant, idle ones too (the row's count chip).
public nonisolated struct SidebarTreeRollUp: Hashable, Sendable {
    public var blocked = 0
    public var failed = 0
    public var running = 0
    public var unread = 0
    public var total = 0

    public init(blocked: Int = 0, failed: Int = 0, running: Int = 0, unread: Int = 0, total: Int = 0) {
        (self.blocked, self.failed, self.running, self.unread, self.total) = (blocked, failed, running, unread, total)
    }

    public init(_ states: some Sequence<SidebarAgentState>) {
        for state in states {
            total += 1
            switch state {
            case .blocked: blocked += 1
            case .failed: failed += 1
            case .running: running += 1
            case .finishedUnread: unread += 1
            case .idle: break
            }
        }
    }

    public var isEmpty: Bool { total == 0 && blocked == 0 && failed == 0 && running == 0 && unread == 0 }
}

/// A tree parent's chevron: its children draw under it, or fold into its roll-up.
public nonisolated enum SidebarTreeFold: Hashable, Sendable {
    case expanded
    case collapsed
}
