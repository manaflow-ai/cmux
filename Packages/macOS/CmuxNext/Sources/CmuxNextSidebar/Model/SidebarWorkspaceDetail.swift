public import Foundation

/// What the workspace hover card says beyond the row's facts (cx-swovq, Lawrence 2026-10-14:
/// "on hover it needs to show how long it has been working on and other useful information").
/// Every fact comes from its owner (the daemon's agent and OSC 7501 records, the terminal's
/// running command, acpmux's chat summary); the bridge only picks the row's one.
public nonisolated struct SidebarWorkspaceDetail: Hashable, Sendable {
    /// When the row's status (`SidebarWorkspace.activity`) began: the earliest start among the
    /// tabs whose status is that state. Nil while the row is idle or no source says.
    public var activitySince: Date?
    /// The model of the row's agent chat (acpmux), nil when unknown.
    public var model: String?
    /// What the row works on: the running turn's prompt of its agent chat, else a working
    /// program's own words (OSC 7501 title and message).
    public var task: String?
    /// Why the row waits for the user: the blocked program's own words, else the newest unread
    /// notification. Nil unless the row waits.
    public var needsInput: String?
    /// The front terminal's running shell command (the row's `process`) while it runs, with
    /// when it started (the daemon's OSC 133 fact).
    public var command: String?
    public var commandSince: Date?
    /// What the workspace's agent chats run below their turns now (acpmux, summed over its
    /// tabs): running subagents, the first of their names, and background commands.
    public var subagentsRunning = 0
    public var subagentNames: [String] = []
    public var commandsRunning = 0

    public init(activitySince: Date? = nil, model: String? = nil, task: String? = nil, needsInput: String? = nil,
                command: String? = nil, commandSince: Date? = nil) {
        self.activitySince = activitySince
        self.model = model
        self.task = task
        self.needsInput = needsInput
        self.command = command
        self.commandSince = commandSince
    }
}
