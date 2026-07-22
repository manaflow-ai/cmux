import CMUXAgentLaunch
import Foundation
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
    func promptEmbeddedLaunchIntoIdleShellTypesOnlyLaunchCommand() {
        let observer = FakeAgentLaunchObserver(state: .idleShell)
        let executor = FakeAgentLaunchExecutor()
        let guardLayer = AgentLaunchGuard(observer: observer, executor: executor)

        let result = guardLayer.perform(
            surfaceID: "surface-1",
            command: "cd /repo && claude",
            intent: .launchThenSubmitPrompt("Explain the bug")
        )

        #expect(result == .launched)
        #expect(executor.launchCommands == ["cd /repo && claude"])
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

    @Test
    func idleObservationAfterFailedLaunchAllowsRelaunch() {
        let observer = FakeAgentLaunchObserver(state: .idleShell)
        let executor = FakeAgentLaunchExecutor()
        let guardLayer = AgentLaunchGuard(observer: observer, executor: executor)

        let first = guardLayer.perform(
            surfaceID: "surface-1",
            command: "missing-agent",
            intent: .launchOnly
        )
        observer.recordObservation(.idleShell)
        let second = guardLayer.perform(
            surfaceID: "surface-1",
            command: "claude",
            intent: .launchOnly
        )

        #expect(first == .launched)
        #expect(second == .launched)
        #expect(executor.launchCommands == ["missing-agent", "claude"])
    }

    @Test
    func onlyObservationStartedAfterLaunchReleasesPendingClaim() {
        let observer = FakeAgentLaunchObserver(state: .idleShell)
        let executor = FakeAgentLaunchExecutor()
        let guardLayer = AgentLaunchGuard(observer: observer, executor: executor)
        let preLaunchObservation = observer.startObservation()

        let first = guardLayer.perform(
            surfaceID: "surface-1",
            command: "missing-agent",
            intent: .launchOnly
        )
        let postLaunchObservation = observer.requestAgentLaunchObservation(surfaceID: "surface-1")
        observer.completeObservation(preLaunchObservation, state: .idleShell)
        let whilePreLaunchDataIsCurrent = guardLayer.perform(
            surfaceID: "surface-1",
            command: "claude",
            intent: .launchOnly
        )
        observer.completeObservation(postLaunchObservation, state: .idleShell)
        let afterPostLaunchObservation = guardLayer.perform(
            surfaceID: "surface-1",
            command: "claude",
            intent: .launchOnly
        )

        #expect(first == .launched)
        #expect(whilePreLaunchDataIsCurrent == .suppressed(.launchAlreadyPending))
        #expect(afterPostLaunchObservation == .launched)
        #expect(executor.launchCommands == ["missing-agent", "claude"])
    }
}

@MainActor
private final class FakeAgentLaunchObserver: AgentLaunchObserving {
    var state: AgentLaunchSurfaceState
    private(set) var observationGeneration: UInt64 = 0
    private var startedObservationGeneration: UInt64 = 0

    init(state: AgentLaunchSurfaceState) {
        self.state = state
    }

    func agentLaunchState(surfaceID: String) -> AgentLaunchSurfaceState {
        state
    }

    func agentLaunchObservationGeneration(surfaceID: String) -> UInt64 {
        observationGeneration
    }

    func requestAgentLaunchObservation(surfaceID: String) -> UInt64 {
        startObservation()
    }

    func startObservation() -> UInt64 {
        startedObservationGeneration &+= 1
        return startedObservationGeneration
    }

    func completeObservation(_ generation: UInt64, state: AgentLaunchSurfaceState) {
        self.state = state
        observationGeneration = max(observationGeneration, generation)
    }

    func recordObservation(_ state: AgentLaunchSurfaceState) {
        completeObservation(startObservation(), state: state)
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

    func submitPrompt(surfaceID: String, text: String, ticketID: UUID?) -> AgentLaunchExecutionResult {
        prompts.append(text)
        return promptResult
    }
}
