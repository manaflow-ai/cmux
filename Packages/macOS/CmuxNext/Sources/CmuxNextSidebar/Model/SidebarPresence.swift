import Foundation

/// One agent acting in a workspace right now (cx-gg84 multiplayer presence):
/// the row draws it as a dot in the agent's color; the dot's tooltip names it
/// and what it touches. An agent that drives the screen or a browser
/// (``drive``) shows on its row with the presence dots off too
/// (`AgentDriveIndicatorView`).
public nonisolated struct SidebarPresence: Identifiable, Hashable, Sendable {
    public enum Activity: Hashable, Sendable {
        case thinking, editing, reading, running, browsing, computerUse, waiting

        /// What the activity drives: the screen (Computer Use) or a browser; nil for quieter work.
        public var drive: SidebarDriveKind? {
            switch self {
            case .computerUse: .screen
            case .browsing: .browser
            case .thinking, .editing, .reading, .running, .waiting: nil
            }
        }
    }

    /// The color key: the agent's session id, else its surface.
    public var id: String
    /// The agent's display name, numbered when two agents in the workspace
    /// share one (`Claude Code 2`).
    public var name: String
    public var activity: Activity
    /// The file it targets, as `name.ext:line`; nil when it targets none.
    public var target: String?
    /// The tab the agent runs in: a click on the row's drive indicator goes there.
    public var tab: TabID?
    /// The person can stop what the agent drives from the row: a Computer Use session, or the turn of an
    /// agent chat that drives a browser. A terminal agent's browser use stops in its terminal.
    public var canStop: Bool

    public init(id: String, name: String, activity: Activity, target: String? = nil, tab: TabID? = nil, canStop: Bool = false) {
        self.id = id
        self.name = name
        self.activity = activity
        self.target = target
        self.tab = tab
        self.canStop = canStop
    }

    /// What the agent drives right now, nil when it drives nothing.
    public var drive: SidebarDriveKind? { activity.drive }
}
