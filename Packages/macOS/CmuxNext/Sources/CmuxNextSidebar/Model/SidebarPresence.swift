import Foundation

/// One agent acting in a workspace right now (cx-gg84 multiplayer presence):
/// the row draws it as a dot in the agent's color; the dot's tooltip names it
/// and what it touches.
public nonisolated struct SidebarPresence: Identifiable, Hashable, Sendable {
    public enum Activity: Hashable, Sendable {
        case thinking, editing, reading, running, browsing, computerUse, waiting
    }

    /// The color key: the agent's session id, else its surface.
    public var id: String
    /// The agent's display name, numbered when two agents in the workspace
    /// share one (`Claude Code 2`).
    public var name: String
    public var activity: Activity
    /// The file it targets, as `name.ext:line`; nil when it targets none.
    public var target: String?

    public init(id: String, name: String, activity: Activity, target: String? = nil) {
        self.id = id
        self.name = name
        self.activity = activity
        self.target = target
    }
}
