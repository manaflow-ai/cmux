import Foundation

/// Agent activity shown as a small indicator on the row.
public nonisolated enum AgentActivity: Hashable, Sendable {
    case idle
    case running
    case needsInput
    case error
}

/// Unread state for the badge.
public nonisolated enum UnreadState: Hashable, Sendable {
    case none
    case dot
    case count(Int)

    public var isUnread: Bool {
        switch self {
        case .none: false
        case .dot: true
        case let .count(n): n > 0
        }
    }
}

/// One workspace row.
public nonisolated struct SidebarWorkspace: Identifiable, Hashable, Sendable {
    public var id: WorkspaceID
    /// The machine whose daemon owns this workspace. Workspaces never move
    /// between machines; drops across machine sections are refused.
    public var machineID: MachineID
    public var title: String
    /// Passive detail (cwd, git branch). Shown in the tooltip and
    /// accessibility label, never as a second line: it rarely changes and
    /// repeats on every row.
    public var subtitle: String?
    /// Live status (`cmux workspace status|progress|log`). The only detail
    /// that earns the row more lines.
    public var status: SidebarWorkspaceStatus?
    /// Set only when the user chose an icon or color. Rows are text-first:
    /// nil shows no icon.
    public var icon: WorkspaceIcon?
    public var unread: UnreadState
    public var activity: AgentActivity

    public init(
        id: WorkspaceID,
        machineID: MachineID = .local,
        title: String,
        subtitle: String? = nil,
        status: SidebarWorkspaceStatus? = nil,
        icon: WorkspaceIcon? = nil,
        unread: UnreadState = .none,
        activity: AgentActivity = .idle
    ) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.icon = icon
        self.unread = unread
        self.activity = activity
    }
}

nonisolated extension SidebarWorkspace {
    /// The status block, when the row carries live information.
    public var liveStatus: SidebarWorkspaceStatus? {
        guard let status, !status.isEmpty else { return nil }
        return status
    }
}
