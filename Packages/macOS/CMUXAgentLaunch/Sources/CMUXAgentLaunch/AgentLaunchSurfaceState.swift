/// The observation-first agent state for one terminal surface.
public enum AgentLaunchSurfaceState: Equatable, Sendable {
    /// The surface currently hosts an idle shell with no observed agent.
    case idleShell
    /// A live agent session or foreground agent process is observed on the surface.
    case runningAgent
    /// The most recent observed agent session on the surface has ended.
    case endedAgent
}
