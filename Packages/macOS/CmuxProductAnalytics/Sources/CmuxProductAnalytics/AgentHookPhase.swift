/// The part of an agent session lifecycle a hook reports.
public enum AgentHookPhase: Sendable, Equatable {
    case sessionStart
    case sessionEnd
    /// Any other hook (prompt, tool use, stop). Tracks a session the app first
    /// sees mid-flight, such as one that outlived a relaunch, without
    /// counting it as started.
    case activity
}
