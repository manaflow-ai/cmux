/// Supplies observation-first agent state for launch decisions.
@MainActor
public protocol AgentLaunchObserving: AnyObject {
    /// Returns the current agent state for `surfaceID`.
    ///
    /// - Parameter surfaceID: The stable terminal surface identifier.
    /// - Returns: The best current session or foreground-process observation.
    func agentLaunchState(surfaceID: String) -> AgentLaunchSurfaceState
}
