import CMUXAgentLaunch
import Testing

@Suite
@MainActor
struct AgentLaunchGuardTests {
    @Test
    func launchIntoIdleShellTypesCommand() {
        let observer = FakeAgentLaunchObserver(state: .idleShell)
        let executor = FakeAgentLaunchExecutor()
        let guardLayer = AgentLaunchGuard(observer: observer, executor: executor)

        let result = guardLayer.perform(
            surfaceID: "surface-1",
            command: "cd /repo && claude",
            intent: .launchOnly
        )

        #expect(result == .launched)
        #expect(executor.launchCommands == ["cd /repo && claude"])
        #expect(executor.prompts.isEmpty)
    }

    @Test
    func launchIntoRunningAgentIsSuppressed() {
        let observer = FakeAgentLaunchObserver(state: .runningAgent)
        let executor = FakeAgentLaunchExecutor()
        let guardLayer = AgentLaunchGuard(observer: observer, executor: executor)

        let result = guardLayer.perform(
            surfaceID: "surface-1",
            command: "cd /repo && claude",
            intent: .launchOnly
        )

        #expect(result == .suppressed(.agentAlreadyRunning))
        #expect(executor.launchCommands.isEmpty)
        #expect(executor.prompts.isEmpty)
    }

    @Test
    func launchThenPromptIntoRunningAgentReroutesPromptOnce() {
        let observer = FakeAgentLaunchObserver(state: .runningAgent)
        let executor = FakeAgentLaunchExecutor()
        let guardLayer = AgentLaunchGuard(observer: observer, executor: executor)

        let result = guardLayer.perform(
            surfaceID: "surface-1",
            command: "cd /repo && claude 'Explain the bug'",
            intent: .launchThenSubmitPrompt("Explain the bug")
        )

        #expect(result == .promptRerouted(queued: false))
        #expect(executor.launchCommands.isEmpty)
        #expect(executor.prompts == ["Explain the bug"])
    }

    @Test
    func doubleLaunchTypesExactlyOneCommand() {
        let observer = FakeAgentLaunchObserver(state: .idleShell)
        let executor = FakeAgentLaunchExecutor()
        let guardLayer = AgentLaunchGuard(observer: observer, executor: executor)

        let first = guardLayer.perform(
            surfaceID: "surface-1",
            command: "cd /repo && claude",
            intent: .launchOnly
        )
        let second = guardLayer.perform(
            surfaceID: "surface-1",
            command: "cd /repo && claude",
            intent: .launchOnly
        )

        #expect(first == .launched)
        #expect(second == .suppressed(.launchAlreadyPending))
        #expect(executor.launchCommands == ["cd /repo && claude"])
    }
}

@MainActor
private final class FakeAgentLaunchObserver: AgentLaunchObserving {
    var state: AgentLaunchSurfaceState

    init(state: AgentLaunchSurfaceState) {
        self.state = state
    }

    func agentLaunchState(surfaceID: String) -> AgentLaunchSurfaceState {
        state
    }
}

@MainActor
private final class FakeAgentLaunchExecutor: AgentLaunchExecuting {
    var launchCommands: [String] = []
    var prompts: [String] = []
    var launchResult = AgentLaunchExecutionResult.accepted
    var promptResult = AgentLaunchExecutionResult.accepted

    func typeLaunchCommand(surfaceID: String, command: String) -> AgentLaunchExecutionResult {
        launchCommands.append(command)
        return launchResult
    }

    func submitPrompt(surfaceID: String, text: String) -> AgentLaunchExecutionResult {
        prompts.append(text)
        return promptResult
    }
}
