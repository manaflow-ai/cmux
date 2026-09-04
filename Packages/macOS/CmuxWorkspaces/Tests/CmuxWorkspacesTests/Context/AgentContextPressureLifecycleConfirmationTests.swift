import Testing
@testable import CmuxWorkspaces

@Suite("Agent context pressure lifecycle confirmation")
struct AgentContextPressureLifecycleConfirmationTests {
    @Test("Idle pressure needs a later running-to-idle boundary")
    func idlePressureNeedsFreshBoundary() {
        var confirmation = AgentContextPressureLifecycleConfirmation()

        confirmation.observePressure(isNewEpisode: true, lifecycle: .idle)
        confirmation.observeLifecycle(.idle)
        #expect(!confirmation.isConfirmed)

        confirmation.observeLifecycle(.running)
        #expect(!confirmation.isConfirmed)
        confirmation.observeLifecycle(.idle)
        #expect(confirmation.isConfirmed)
    }

    @Test("Pressure observed while running is confirmed by the next idle")
    func runningPressureUsesCurrentTurnBoundary() {
        var confirmation = AgentContextPressureLifecycleConfirmation()

        confirmation.observePressure(isNewEpisode: true, lifecycle: .running)
        #expect(!confirmation.isConfirmed)
        confirmation.observeLifecycle(.idle)

        #expect(confirmation.isConfirmed)
    }

    @Test("A new running edge invalidates earlier confirmation")
    func runningEdgeInvalidatesConfirmation() {
        var confirmation = AgentContextPressureLifecycleConfirmation()
        confirmation.observePressure(isNewEpisode: true, lifecycle: .running)
        confirmation.observeLifecycle(.idle)
        #expect(confirmation.isConfirmed)

        confirmation.observeLifecycle(.running)
        confirmation.observePressure(isNewEpisode: false, lifecycle: .running)

        #expect(!confirmation.isConfirmed)
    }

    @Test("Unknown lifecycle clears accumulated evidence")
    func unknownLifecycleClearsEvidence() {
        var confirmation = AgentContextPressureLifecycleConfirmation()
        confirmation.observePressure(isNewEpisode: true, lifecycle: .running)

        confirmation.observeLifecycle(.unknown)
        confirmation.observeLifecycle(.idle)

        #expect(!confirmation.isConfirmed)
    }
}
