/// Supplies observation-first agent state for launch decisions.
@MainActor
public protocol AgentLaunchObserving: AnyObject {
    /// Returns the current agent state for `surfaceID`.
    ///
    /// - Parameter surfaceID: The stable terminal surface identifier.
    /// - Returns: The best current session or foreground-process observation.
    func agentLaunchState(surfaceID: String) -> AgentLaunchSurfaceState

    /// Returns the generation of the most recently completed process observation.
    ///
    /// - Parameter surfaceID: The stable terminal surface identifier.
    /// - Returns: A monotonically increasing completed-observation generation.
    func agentLaunchObservationGeneration(surfaceID: String) -> UInt64

    /// Requests a cache-bypassing process observation after a launch is accepted.
    ///
    /// - Parameter surfaceID: The stable terminal surface identifier.
    /// - Returns: The generation reserved for the post-launch observation.
    func requestAgentLaunchObservation(surfaceID: String) -> UInt64
}
