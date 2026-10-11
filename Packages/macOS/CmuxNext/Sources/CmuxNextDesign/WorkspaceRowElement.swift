/// What a sidebar workspace row shows (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE,
/// `sidebar.workspaceRow.*` in cmux.json). The default row is the name, the
/// user's icon when one is set, and the unread/attention mark; every other
/// element is off until the user turns it on, for all workspaces or for one
/// kind of workspace.
public nonisolated enum WorkspaceRowElement: String, CaseIterable, Hashable, Sendable {
    /// The icon or emoji the user chose (no kind glyph is ever drawn).
    case icon
    /// The folder of the first tab that reports one, `~`-abbreviated.
    case directory
    /// That tab's git branch.
    case branch
    /// The front terminal's program, as the shell or program titles it.
    case process
    /// The status line agents and hooks report (`cmux workspace status set`).
    case agentStatus
    /// How many tabs the workspace has.
    case tabCount
    /// Listening ports, as a hook reports them (`status set ports …`).
    case ports
    /// When an agent or a notification last changed the workspace.
    case lastActivity
    /// A pull request / CI badge, as a hook reports it (`status set pr …`).
    case pullRequest
    /// A terminal's or the workspace's progress: the bar under the row and
    /// the busy glyph of work that is not an agent turn.
    case progress
    /// The agent-working indicator (WORKING-AND-LOADING-INDICATORS).
    case working

    /// The elements that make up the second line, in their default order.
    public static let secondLine: [Self] = [.directory, .branch, .process, .agentStatus, .ports, .lastActivity]

    public var isSecondLine: Bool { Self.secondLine.contains(self) }
}

/// The kind of a workspace for per-kind row settings: what its tabs are.
public nonisolated enum WorkspaceRowKind: String, CaseIterable, Hashable, Sendable {
    /// Only terminals (or no tabs yet).
    case terminal
    /// Only agents: agent chats, Home conversations, agent terminals.
    case agent
    /// Only browser pages.
    case browser
    /// Tabs of more than one kind.
    case mixed
}
