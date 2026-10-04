import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// W7 compares the published registry context with the focus model's
/// context. The observation must read every focus fact the applier
/// publishes: an agent page (the new tab page) is agentPaneFocused, else
/// W7 reports a false mismatch after every new tab.
@MainActor
struct InputObservationContextTests {
    @Test func theObservationReadsTheAgentFocusBit() {
        let services = KeyOwnershipMatrixTests.services()
        services.registry.context = [.agentPaneFocused]
        #expect(InputObservationBuilder.observe(services).context == FocusState.Context(agent: true))
        services.registry.context = [.terminalFocused]
        #expect(InputObservationBuilder.observe(services).context == FocusState.Context(terminal: true))
    }
}
