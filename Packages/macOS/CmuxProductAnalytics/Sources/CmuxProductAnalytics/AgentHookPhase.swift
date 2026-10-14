/// The part of an agent session lifecycle a hook reports.
public enum AgentHookPhase: Sendable {
    case sessionStart
    case sessionEnd
    /// Any other hook (prompt, tool use, stop). Starts a session the app
    /// first sees mid-flight, such as one resumed before launch.
    case activity
}
