/// The agent acting in a tab right now (cx-gg84), as the strip shows it.
public struct TabPresence: Hashable, Sendable {
    /// The agent's color key (its session id), for `AgentPresenceColor`.
    public var colorKey: String
    /// Who is doing what, for VoiceOver: `Claude Code · Editing app.rs:42`.
    public var summary: String

    public init(colorKey: String, summary: String) {
        self.colorKey = colorKey
        self.summary = summary
    }
}
