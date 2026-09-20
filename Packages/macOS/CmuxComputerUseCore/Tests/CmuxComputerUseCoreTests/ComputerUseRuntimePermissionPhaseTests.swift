import Testing
@testable import CmuxComputerUseCore

@Suite("Computer Use core state")
struct ComputerUseRuntimePermissionPhaseTests {
    @Test func disabledSetupRequiresExplicitPresentation() {
        let disabled = ComputerUseRuntimePermissionPhase.disabled(onboardingComplete: false)
        #expect(disabled.applying(.setEnabled(true)) == .onboardingRequired)
        #expect(disabled.applying(.onboardingPresented) == disabled)
    }

    @Test func replacementInvalidatesReadiness() {
        let ready = ComputerUseRuntimePermissionPhase.ready
        #expect(ready.applying(.helperReplaced) == .onboardingRequired)
        #expect(ready.applying(.setEnabled(false)) == .disabled(onboardingComplete: true))
    }
}
