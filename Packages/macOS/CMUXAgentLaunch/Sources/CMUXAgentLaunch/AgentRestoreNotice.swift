/// Something a restore changed about the recorded launch that the user should
/// see before the agent starts.
public enum AgentRestoreNotice: Equatable, Sendable {
    /// The session was started through a routed launcher that cannot be found
    /// on the restore `PATH`, so the agent resumes directly instead.
    case routedLauncherUnavailable(executable: String)
}
