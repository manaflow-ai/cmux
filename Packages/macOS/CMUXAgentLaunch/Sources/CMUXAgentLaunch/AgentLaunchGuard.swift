import Foundation

/// Serializes agent launches and prevents commands from being typed into a running agent.
@MainActor
public final class AgentLaunchGuard {
    private let observer: any AgentLaunchObserving
    private let executor: any AgentLaunchExecuting
    private var pendingSurfaceIDs: Set<String> = []

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
    /// A successful launch claims the surface until an agent observation appears or an ended
    /// session is observed. This closes the window where two quick requests both see the same
    /// idle shell before the launched process becomes observable.
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
        if state != .idleShell {
            pendingSurfaceIDs.remove(surfaceID)
        }

        if state == .runningAgent {
            return handleRunningAgent(surfaceID: surfaceID, intent: intent)
        }
        if pendingSurfaceIDs.contains(surfaceID) {
            return .suppressed(.launchAlreadyPending)
        }

        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return .failed("empty_launch_command")
        }
        pendingSurfaceIDs.insert(surfaceID)
        switch executor.typeLaunchCommand(surfaceID: surfaceID, command: trimmedCommand) {
        case .accepted, .queued:
            return submitInitialPromptIfNeeded(surfaceID: surfaceID, intent: intent)
        case .failed(let code):
            pendingSurfaceIDs.remove(surfaceID)
            return .failed(code)
        }
    }

    private func submitInitialPromptIfNeeded(
        surfaceID: String,
        intent: AgentLaunchIntent
    ) -> AgentLaunchGuardResult {
        guard case .launchThenSubmitPrompt(let prompt) = intent else { return .launched }
        switch executor.submitPrompt(surfaceID: surfaceID, text: prompt) {
        case .accepted, .queued:
            return .launched
        case .failed(let code):
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
        case .launchThenSubmitPrompt(let prompt):
            switch executor.submitPrompt(surfaceID: surfaceID, text: prompt) {
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
