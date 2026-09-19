import CmuxSettingsUI
import Testing

@Suite("Agent integration install presentation")
struct AgentIntegrationPresentationTests {
    @Test(arguments: [
        (AgentIntegrationInstallState.missing, AgentIntegrationDisplayState.missing, [AgentIntegrationInstallAction.install, .openInstructions]),
        (AgentIntegrationInstallState.installed, AgentIntegrationDisplayState.installed, [AgentIntegrationInstallAction.remove, .openInstructions]),
        (AgentIntegrationInstallState.stale, AgentIntegrationDisplayState.stale, [AgentIntegrationInstallAction.repair, .remove, .openInstructions]),
    ])
    func enabledStatesExposeBoundedActions(
        state: AgentIntegrationInstallState,
        display: AgentIntegrationDisplayState,
        actions: [AgentIntegrationInstallAction]
    ) {
        let presentation = AgentIntegrationPresentation(isEnabled: true, installState: state)
        #expect(presentation.displayState == display)
        #expect(presentation.availableActions == actions)
    }

    @Test func disabledIntegrationHidesLifecycleActions() {
        let presentation = AgentIntegrationPresentation(isEnabled: false, installState: .installed)
        #expect(presentation.displayState == .disabled)
        #expect(presentation.availableActions == [.remove, .openInstructions])
    }

    @Test func checkingAndUnavailableStatesStayBounded() {
        #expect(AgentIntegrationPresentation(isEnabled: true, installState: .checking).availableActions.isEmpty)
        #expect(AgentIntegrationPresentation(isEnabled: true, installState: .unavailable).availableActions == [.openInstructions])
        #expect(AgentIntegrationPresentation(isEnabled: true, installState: .conflict).availableActions == [.openInstructions])
    }
}
