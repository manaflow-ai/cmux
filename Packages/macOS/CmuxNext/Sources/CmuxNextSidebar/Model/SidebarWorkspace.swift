import Foundation

/// One workspace row.
public nonisolated struct SidebarWorkspace: Identifiable, Hashable, Sendable {
    public var id: WorkspaceID
    /// The machine whose daemon owns this workspace. Workspaces never move
    /// between machines; drops across machine sections are refused.
    public var machineID: MachineID
    public var title: String
    /// cwd, git branch, or the agent status line.
    public var subtitle: String?
    public var icon: WorkspaceIcon
    public var unread: UnreadState
    public var activity: AgentActivity

    public init(
        id: WorkspaceID,
        machineID: MachineID = .local,
        title: String,
        subtitle: String? = nil,
        icon: WorkspaceIcon = .symbol("terminal"),
        unread: UnreadState = .none,
        activity: AgentActivity = .idle
    ) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.unread = unread
        self.activity = activity
    }
}
