import Foundation

/// Serializes agent launches and prevents commands from being typed into a running agent.
@MainActor
public final class AgentLaunchGuard {
    private let observer: any AgentLaunchObserving
    private let executor: any AgentLaunchExecuting
    private var requiredPostLaunchObservationBySurfaceID: [String: UInt64] = [:]

    /// Creates a guard with injected observation and terminal mutation seams.
    ///
    /// - Parameters:
    ///   - observer: The observation-first source of current agent state.
    ///   - executor: The only object allowed to mutate the terminal for this launch path.
    public init(observer: any AgentLaunchObserving, executor: any AgentLaunchExecuting) {
        self.observer = observer
        self.executor = executor
    }

    /// Performs a guarded launch or reroutes its prompt to the running agent.
    ///
    /// A successful launch claims the surface until its cache-bypassing post-launch process
    /// observation completes. Observations started before the launch cannot release that claim.
    /// A post-launch observation that still sees an idle shell releases a failed or instant-exit
    /// launch.
    ///
    /// - Parameters:
    ///   - surfaceID: The stable terminal surface identifier.
    ///   - command: The complete agent launch shell command.
    ///   - intent: Whether the request only launches or also carries a prompt.
    /// - Returns: The launch, suppression, reroute, or terminal-failure outcome.
    public func perform(
        surfaceID: String,
        command: String,
        intent: AgentLaunchIntent
    ) -> AgentLaunchGuardResult {
        let state = observer.agentLaunchState(surfaceID: surfaceID)
        let observationGeneration = observer.agentLaunchObservationGeneration(surfaceID: surfaceID)
        if state != .idleShell
            || requiredPostLaunchObservationBySurfaceID[surfaceID].map({ observationGeneration >= $0 }) == true {
            requiredPostLaunchObservationBySurfaceID.removeValue(forKey: surfaceID)
        }

        if state == .runningAgent {
            return handleRunningAgent(surfaceID: surfaceID, intent: intent)
        }
        if requiredPostLaunchObservationBySurfaceID[surfaceID] != nil {
            return .suppressed(.launchAlreadyPending)
        }

        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return .failed("empty_launch_command")
        }
        requiredPostLaunchObservationBySurfaceID[surfaceID] = .max
        switch executor.typeLaunchCommand(surfaceID: surfaceID, command: trimmedCommand) {
        case .accepted, .queued:
            requiredPostLaunchObservationBySurfaceID[surfaceID] = observer.requestAgentLaunchObservation(
                surfaceID: surfaceID
            )
            return .launched
        case .failed(let code):
            requiredPostLaunchObservationBySurfaceID.removeValue(forKey: surfaceID)
            return .failed(code)
        }
    }

    private func handleRunningAgent(
        surfaceID: String,
        intent: AgentLaunchIntent
    ) -> AgentLaunchGuardResult {
        switch intent {
        case .launchOnly:
            return .suppressed(.agentAlreadyRunning)
        case .launchThenSubmitPrompt(let prompt, let ticketID):
            switch executor.submitPrompt(surfaceID: surfaceID, text: prompt, ticketID: ticketID) {
            case .accepted:
                return .promptRerouted(queued: false)
            case .queued:
                return .promptRerouted(queued: true)
            case .failed(let code):
                return .failed(code)
            }
        }
    }
}
